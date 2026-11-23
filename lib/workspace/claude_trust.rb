require "json"

module Workspace
  # Writes Claude Code's trust flag (`hasTrustDialogAccepted`) for a checkout
  # into its `.claude.json`, so a new worktree's agent does not stop at the
  # trust dialog. Only ever merges one key; any file it cannot read as the
  # expected shape is left as it is.
  class ClaudeTrust
    # @param env [Hash, #[]] environment; `CLAUDE_CONFIG_DIR` moves the config file
    # @param home [String] home directory holding `.claude.json` by default
    # @param trust_config [Workspace::ClaudeTrustConfig, nil] reads `agent.claude.trust_checkout`;
    #   nil leaves #trust_checkout trusting nothing
    # @param main_agent [Workspace::MainAgent, nil] says which agent a workspace runs
    # @param error_output [IO] where the unparseable-file warning goes
    def initialize(env: ENV, home: Dir.home, trust_config: nil, main_agent: nil, error_output: $stderr)
      @env = env
      @home = home
      @trust_config = trust_config
      @main_agent = main_agent
      @error_output = error_output
    end

    # The one gate `launch`, `start` and `add` share: trusts +root+ only when
    # `agent.claude.trust_checkout` is on for +workspace+ and its main agent is
    # Claude Code. The key is read before any file is touched.
    #
    # @param workspace [String] the workspace name
    # @param root [String, nil] its checkout
    # @return [Symbol, nil] what #trust returned, or nil when the gate is closed
    def trust_checkout(workspace, root)
      return nil unless root && @trust_config && @main_agent
      return nil unless @trust_config.enabled?(workspace)
      return nil unless @main_agent.kind(workspace) == "claude"
      trust(root)
    end

    # @param root [String] a checkout #trust_checkout just trusted
    # @return [String] the line `launch`, `start` and `add` print for it
    def trusted_note(root)
      "Note: marked #{root} as trusted in #{config_path} (agent.claude.trust_checkout)."
    end

    # @return [String] path of the `.claude.json` Claude Code reads
    def config_path
      dir = @env["CLAUDE_CONFIG_DIR"].to_s
      base = (!dir.empty? && File.absolute_path?(dir)) ? dir : @home
      File.join(base, ".claude.json")
    end

    # Marks a directory trusted. A symlinked config file is written through to
    # its target. Claude Code rewrites the file while it runs and its lock can
    # not be taken, so the write is checked by reading the file back, and done
    # once more if another writer replaced it.
    #
    # @param dir [String] the checkout
    # @return [Symbol] `:trusted`, `:already`, `:missing` (no config file),
    #   `:skipped` (no such directory), `:unparseable` (file left unchanged, warned)
    #   or `:unwritten` (an error or another writer kept the flag out, warned)
    def trust(dir)
      path = config_path
      real = resolve(dir)
      return :skipped unless real
      return :missing unless File.file?(path)

      path = File.realpath(path)
      doc = read(path, real)
      return :unparseable unless doc
      return :already if trusted?(doc, real)

      2.times do
        write(path, doc, real)
        doc = read(path, real)
        return :unparseable unless doc
        return :trusted if trusted?(doc, real)
      end
      unwritten(path, "another program kept replacing it")
    rescue => e
      unwritten(path, e.message)
    end

    private

    def read(path, real)
      doc = JSON.parse(File.read(path))
      projects = doc.is_a?(Hash) ? doc["projects"] : nil
      valid = doc.is_a?(Hash) &&
        (!doc.key?("projects") || (projects.is_a?(Hash) && (!projects.key?(real) || projects[real].is_a?(Hash))))
      return doc if valid
      warn_unchanged(path)
      nil
    rescue JSON::ParserError
      warn_unchanged(path)
      nil
    end

    def resolve(dir)
      File.realpath(dir)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def unwritten(path, reason)
      Warn.puts(@error_output, "Could not update #{path} (#{reason}); the checkout is not marked trusted.")
      :unwritten
    end

    def warn_unchanged(path)
      Warn.puts(@error_output, "Could not read #{path} as Claude Code's config; left it unchanged, so the checkout is not marked trusted.")
    end

    def trusted?(doc, real)
      doc.is_a?(Hash) && doc.dig("projects", real, "hasTrustDialogAccepted") == true
    end

    def write(path, doc, real)
      doc["projects"] ||= {}
      doc["projects"][real] ||= {}
      doc["projects"][real]["hasTrustDialogAccepted"] = true
      mode = File.stat(path).mode & 0o777
      AtomicFile.write(path, JSON.pretty_generate(doc) + "\n", perm: mode)
      File.chmod(mode, path)
    end
  end
end
