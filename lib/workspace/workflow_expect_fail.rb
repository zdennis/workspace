require "fileutils"
require "shellwords"
require "tmpdir"

module Workspace
  # The fail-first check behind `workspace step expect-fail`: runs the project's `commands.test` on the
  # given test files and passes only when it fails (and, with a match file, its output holds that file's
  # text). A `require: exec:` proof runs it from no pane, with its working directory at the checkout, so
  # it finds the workspace from that directory alone, never from `TMUX_PANE` or a pane binding.
  class WorkflowExpectFail
    # Seconds the tests may run when no limit is given; below the engine's 300s `exec` default, so a
    # slow run ends with this check's own message instead of the engine's stop.
    DEFAULT_TIMEOUT = 240

    # Bytes of the tests' output kept for printing: the last ones.
    OUTPUT_KEEP = 1024 * 1024

    # Bytes of the log read at a time while looking for the match text.
    BLOCK = 64 * 1024

    # The most bytes a match file may hold.
    MATCH_MAX = 4096

    # What one check came to.
    #
    # @!attribute passed [Boolean] the tests failed as expected
    # @!attribute message [String] one line, starting `expect-fail:`
    # @!attribute output [String, nil] the last {OUTPUT_KEEP} bytes of the tests' stdout and stderr, nil when they never ran
    # @!attribute cut [Boolean] whether earlier output was left out of +output+
    Result = Struct.new(:passed, :message, :output, :cut, keyword_init: true)

    # @param lineage [Workspace::WorkspaceLineage] finds the workspace of the checkout
    # @param commands_config [Workspace::CommandsConfig] the workspace's `commands.test`, through every layer
    # @param checker [Workspace::WorkflowCheck] runs the command through `sh -c` in its own process group
    # @param tmp_root [String] where the log's temporary directory is made
    # @param output_keep [Integer] see {OUTPUT_KEEP}
    # @param block [Integer] see {BLOCK}
    def initialize(lineage:, commands_config:, checker:, tmp_root: Dir.tmpdir, output_keep: OUTPUT_KEEP, block: BLOCK)
      @lineage = lineage
      @commands_config = commands_config
      @checker = checker
      @tmp_root = tmp_root
      @output_keep = output_keep
      @block = block
    end

    # @param cwd [String] the checkout the tests run in
    # @param files [Array<String>] the test files, appended to `commands.test` shell-escaped
    # @param match_file [String, nil] a file whose trimmed text the tests' output must hold; relative to +cwd+
    # @param timeout [Integer] seconds the tests may run
    # @return [Result]
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def call(cwd:, files:, match_file: nil, timeout: DEFAULT_TIMEOUT)
      return refused("no test files given; a fail-first proof needs the files of the new test") if files.empty?
      option_like = files.find { |file| file.start_with?("-") }
      return refused("test file #{option_like.inspect} starts with -, so the test command would read it as an option; give a path such as ./#{option_like}") if option_like
      lineage = @lineage.resolve(cwd: cwd)
      workspace = lineage.worktree || lineage.name
      command = @commands_config.for_project(workspace)[:test]
      return refused("commands.test is unset for #{workspace}; set it: workspace config set commands.test \"<test command>\" --name #{workspace}") unless command
      expected = nil
      if match_file
        expected, why = expected_text(File.expand_path(match_file, cwd))
        return refused(why) if why
      end
      run(command: [command, *files.map { |file| Shellwords.escape(file) }].join(" "), cwd: cwd, timeout: timeout, expected: expected, match_file: match_file)
    end

    private

    def run(command:, cwd:, timeout:, expected:, match_file:)
      dir = Dir.mktmpdir("workspace-expect-fail-", @tmp_root)
      log = File.join(dir, "tests.log")
      result = @checker.call(command: command, cwd: cwd, timeout: timeout, log: log)
      output, cut, found = File.exist?(log) ? scan(log, expected) : [nil, false, false]
      Result.new(**verdict(result, found, timeout, expected, match_file), output: output, cut: cut)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    # Reads the log a block at a time: keeps its last bytes and looks for +expected+, carrying the end of
    # each block into the next so a match across two blocks is found.
    #
    # @return [Array(String, Boolean, Boolean)] the kept output, whether it was cut, whether +expected+ was found
    def scan(log, expected)
      tail = +"".b
      carry = +"".b
      found = false
      cut = false
      File.open(log, "rb") do |file|
        while (chunk = file.read(@block))
          if expected && !found
            window = carry + chunk
            found = window.include?(expected)
            carry = window.byteslice([window.bytesize - expected.bytesize + 1, 0].max..)
          end
          tail << chunk
          next unless tail.bytesize > @output_keep
          cut = true
          tail = tail.byteslice(-@output_keep..)
        end
      end
      [tail, cut, found]
    end

    def verdict(result, found, timeout, expected, match_file)
      return {passed: false, message: "expect-fail: tests ran past #{timeout}s and were stopped"} if result[:timed_out]
      code = result[:exit_code]
      return {passed: false, message: "expect-fail: the tests could not run: #{result[:error] || "no exit status"}"} if code.nil?
      return {passed: false, message: "expect-fail: the tests passed (exit 0); a fail-first test must fail before the fix"} if code.zero?
      if expected && !found
        return {passed: false, message: "expect-fail: the tests failed (exit #{code}) but their output does not hold the text of #{match_file} (trimmed, as one exact substring)"}
      end
      {passed: true, message: "expect-fail: the tests failed as expected (exit #{code})#{" with the text of #{match_file}" if expected}"}
    end

    # A link is not followed, and a file over {MATCH_MAX} bytes is refused.
    #
    # @return [Array(String, nil)] the match file's trimmed text, or nil and why it can't be used
    def expected_text(path)
      info = begin
        File.lstat(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        return [nil, "match file #{path} is missing"]
      end
      return [nil, "match file #{path} is a link; give the file itself"] if info.symlink?
      return [nil, "match file #{path} is not a regular file"] unless info.file?
      return [nil, "match file #{path} is over #{MATCH_MAX} bytes"] if info.size > MATCH_MAX
      text = File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(MATCH_MAX + 1) }.to_s.b.strip
      return [nil, "match file #{path} is over #{MATCH_MAX} bytes"] if text.bytesize > MATCH_MAX
      return [nil, "match file #{path} is empty"] if text.empty?
      [text, nil]
    rescue SystemCallError => e
      [nil, "match file #{path} can't be read (#{e.class})"]
    end

    def refused(why)
      Result.new(passed: false, message: "expect-fail: #{why}", output: nil, cut: false)
    end
  end
end
