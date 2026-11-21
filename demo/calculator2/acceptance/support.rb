require "minitest/autorun"
require "open3"
require "json"
require "rbconfig"
require "timeout"

# Black-box helpers: run the calculator's bin/calc as a child process and read what it prints.
module CalcSupport
  Result = Struct.new(:out, :err, :status) do
    def success? = status.success?

    def code = status.exitstatus
  end

  def calc_root
    File.join(ENV.fetch("CALC2_ROOT"), "demo", "calculator2")
  end

  # @param args [Array<String>] arguments for bin/calc
  # @param stdin [String, nil] text written to its standard input, then closed
  # @return [Result]
  def calc(*args, stdin: nil, timeout: 10)
    Open3.popen3(RbConfig.ruby, File.join(calc_root, "bin", "calc"), *args) do |i, o, e, thread|
      i.write(stdin) if stdin
      i.close
      begin
        Timeout.timeout(timeout) do
          out = o.read
          err = e.read
          Result.new(out, err, thread.value)
        end
      rescue Timeout::Error
        Process.kill("KILL", thread.pid)
        flunk "bin/calc did not finish within #{timeout}s"
      end
    end
  end

  # Asserts the expression prints a number equal to expected and exits 0. Formatting (3 or 3.0) is not checked.
  def assert_value(expected, expression)
    r = calc(expression)
    assert r.success?, "#{expression.inspect} exited #{r.code}: #{r.err}"
    assert_in_delta expected, Float(r.out.strip), 1e-9, "#{expression.inspect} printed #{r.out.inspect}"
  end

  def assert_division_by_zero(expression)
    r = calc(expression)
    assert_equal 1, r.code, "#{expression.inspect} should exit 1"
    assert_includes r.err.lines.map(&:chomp), "error: division by zero"
  end
end
