require "open3"

module Workspace
  # Builds Claude Code's status line: model, directory, git branch, a context
  # usage bar, session cost, and turn duration. Ports
  # `~/.claude/statusline-command.sh`, minus the usage API call — that hit
  # `https://api.anthropic.com`, and `workspace` never calls an external URL.
  #
  # Reads only the stdin JSON Claude Code passes to a `statusLine` command and
  # local git; nothing here makes a network request.
  class StatuslineRenderer
    CYAN = "\033[36m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    RESET = "\033[0m"
    private_constant :CYAN, :GREEN, :YELLOW, :RED, :RESET

    # @param logger [Workspace::Logger] debug logger
    def initialize(logger: Workspace::Logger.new)
      @logger = logger
    end

    # @param payload [Hash] Claude Code's status-line stdin JSON
    # @param cwd [String] working directory to fall back to, and to resolve
    #   the git branch from, when the payload doesn't carry one
    # @return [String] the rendered status line (may be multiple lines)
    def render(payload, cwd: Dir.pwd)
      model = payload.dig("model", "display_name") || "unknown"
      dir = payload["cwd"] || payload.dig("workspace", "project_dir") || cwd
      cost = (payload.dig("cost", "total_cost_usd") || 0).to_f
      pct = valid_pct(payload.dig("context_window", "used_percentage"))
      duration_ms = (payload.dig("cost", "total_duration_ms") || 0).to_i

      branch = git_branch(dir)
      bar = context_bar(pct)
      pct_label = pct.nil? ? "?" : pct.to_s
      mins, secs = duration_ms.divmod(60_000).then { |m, r| [m, r / 1000] }

      lines = []
      lines << "#{CYAN}[#{model}]#{RESET} #{File.basename(dir)}#{" | #{branch}" if branch}"
      lines << "#{bar_color(pct)}#{bar}#{RESET} #{pct_label}% ctx | #{YELLOW}#{format("$%.2f", cost)}#{RESET} | #{mins}m #{secs}s"
      lines.join("\n")
    rescue => e
      @logger.debug { "statusline_renderer: render failed (#{e.class}: #{e.message})" }
      "workspace statusline: unavailable"
    end

    private

    # Coerces a raw `used_percentage` value into a sane 0..100 integer, or
    # nil when it isn't one (a string like "N/A", NaN, or an out-of-range
    # number) -- never guessed, and never rendered as a fabricated reading.
    def valid_pct(raw)
      return nil unless raw.is_a?(Numeric) && (0..100).cover?(raw)
      raw.round
    end

    def bar_color(pct)
      return GREEN if pct.nil?
      return RED if pct >= 90
      return YELLOW if pct >= 70
      GREEN
    end

    def context_bar(pct)
      return "░" * 10 if pct.nil?
      filled = (pct / 10).clamp(0, 10)
      empty = 10 - filled
      ("█" * filled) + ("░" * empty)
    end

    def git_branch(dir)
      return nil unless Dir.exist?(dir)
      stdout, _, status = Open3.capture3("git", "-C", dir, "branch", "--show-current")
      return nil unless status.success?
      branch = stdout.strip
      branch.empty? ? nil : branch
    rescue SystemCallError, IOError
      nil
    end
  end
end
