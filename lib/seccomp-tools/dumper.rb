require 'seccomp-tools/ptrace'
require 'seccomp-tools/syscall'

module SeccompTools
  # Dump seccomp-bpf using ptrace of binary.
  # Currently only support x86_64.
  module Dumper
    module_function

    # Main bpf dump function.
    # Yield seccomp bpf whenever find a +prctl(SET_SECCOMP)+ call.
    #
    # @param [Array<String>] args
    #   The arguments for target execution file.
    # @param [Integer] limit
    #   By default, +dump+ will only dump the first +SET_SECCOMP+ call.
    #   Set +limit+ to the number of calling +prctl(SET_SECCOMP)+ then the child process will be killed when number of
    #   calling +prctl+ reaches +limit+.
    #
    #   Negative number or zero for unlimited.
    # @yieldparam [String] bpf
    #   Seccomp bpf in raw bytes.
    # @return [Array<Object>, Array<String>]
    #   Return the block returned. If block is not given, array of raw bytes will be returned.
    # @example
    #   dump('ls', '-l', '-a')
    #   #=> []
    #   dump('spec/binary/twctf-2016-diary') { |c| c[0, 10] }
    #   #=> [" \x00\x00\x00\x00\x00\x00\x00\x15\x00"]
    # @todo
    #   Detect execution file architecture to know which syscall number should be traced.
    # @todo
    #   +timeout+ option.
    def dump(*args, limit: 1, &block)
      pid = fork { handle_child(*args) }
      Handler.new(pid).handle(limit, &block)
    end

    # Do the tracer things.
    class Handler
      attr_reader :pid
      def initialize(pid)
        @pid = pid
      end

      # Tracer.
      #
      # @param [Integer] limit
      #   Child will be killed when number of calling +prctl(SET_SECCOMP)+ reaches +limit+.
      # @yieldparam [String] bpf
      #   Seccomp bpf in raw bytes.
      # @return [Array<Object>, Array<String>]
      #   Return the block returned. If block is not given, array of raw bytes will be returned.
      def handle(limit, &block)
        Process.waitpid(pid)
        SeccompTools::Ptrace.setoptions(pid, 0, 1) # TODO: PTRACE_O_TRACESYSGOOD
        collect = []
        loop do
          break unless wait_syscall
          sys = syscall
          break unless wait_syscall
          # TODO: maybe the prctl(SET_SECCOMP) call failed?
          next unless sys.set_seccomp?
          bpf = dump_bpf(sys.args[2])
          collect << (block.nil? ? bpf : yield(bpf))
          limit -= 1
          break if limit.zero?
        end
        Process.kill('KILL', pid) if alive?
        collect
      end

      private

      # @return [Boolean]
      #   Return +false+ if and only if child exited.
      def wait_syscall
        loop do
          SeccompTools::Ptrace.syscall(pid, 0, 0)
          _, status = Process.waitpid2(pid)
          return true if status.stopped? && status.stopsig & 0x80 != 0
          return false if status.exited?
        end
      end

      # @return [SeccompTools::Syscall]
      def syscall
        SeccompTools::Syscall.new('amd64') do |offset|
          Ptrace.peekuser(pid, offset, 0)
        end
      end

      # Dump bpf from addr.
      def dump_bpf(addr)
        len = Ptrace.peekdata(pid, addr, 0) & 0xffff # len is unsigned short
        # TODO: Use __buildin_offset instead of hardcode
        filter = Ptrace.peekdata(pid, addr + 8, 0)
        Array.new(len) { |i| Ptrace.peekdata(pid, filter + i * 8, 0) }.pack('Q*')
      end

      def alive?
        Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    class << self
      private

      def handle_child(*args)
        SeccompTools::Ptrace.traceme_and_stop
        exec(*args)
      rescue # exec fail
        exit(1)
      end
    end
  end
end