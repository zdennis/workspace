require "fileutils"

module Workspace
  # The opt-in launchd entry that runs `workflow sweep` every five minutes: one
  # per-user LaunchAgent plist and its load state. It is made only by
  # `workflow sweep --install`, never by `doctor --fix` or another command.
  #
  # The plist records absolute paths read at install time (Ruby, the `workspace`
  # program, a PATH holding both Ruby's and tmux's directory), because launchd's
  # own PATH finds the system Ruby, which cannot load this code. Homebrew paths
  # are the stable `opt` ones. Output goes to /dev/null, so nothing grows.
  # `launchctl` and the LaunchAgents directory are injected; nothing here runs a
  # real one unless the composition root hands it over.
  class SweepSchedule
    LABEL = "com.workspace.workflow-sweep".freeze

    # The line that marks a plist as this tool's; a file without it is never touched.
    MARKER = "<!-- written by `workspace workflow sweep --install`; remove with --uninstall -->".freeze

    LABEL_LINE = %r{<key>Label</key>\s*<string>#{Regexp.escape(LABEL)}</string>}

    INTERVAL = 300

    BASE_PATH = %w[/usr/bin /bin /usr/sbin /sbin].freeze

    # @param agents_dir [String] the user's LaunchAgents directory
    # @param launchctl [#call] takes an argument array, answers `[output, exit_code]`; the code is nil when launchctl could not run or timed out
    # @param source [#executable] where the `workspace` program is (a {SkillSource})
    # @param ruby [String] the Ruby that runs it (`RbConfig.ruby`)
    # @param which [#call] program name to absolute path or nil (`Which.method(:path)`)
    # @param uid [Integer] the user whose `gui/UID` domain the entry loads into
    def initialize(agents_dir:, launchctl:, source:, ruby:, which:, uid:)
      @agents_dir = agents_dir
      @launchctl = launchctl
      @source = source
      @ruby = ruby
      @which = which
      @uid = uid
    end

    # Writes the plist and loads it. Safe to repeat: a plist already as it would be
    # written and loaded changes nothing, and a retry after a failed `launchctl`
    # finishes the load.
    #
    # @param dry_run [Boolean] say what would be done and change nothing
    # @return [Hash{String=>Object}] a result row; `outcome` is `installed`, `updated`, `loaded`, `unchanged` or `dry_run`
    # @raise [Workspace::Error] `sweep_entry_foreign`, `sweep_source_worktree`, `sweep_program_missing`, `sweep_launchctl_failed`
    def install(dry_run: false)
      refuse_foreign!
      text = plist
      existing = read
      loaded = loaded?
      remove_stray_temps unless dry_run
      changed = existing != text
      action = if changed && loaded then "replace and reload"
      elsif changed then "write and load"
      elsif loaded then nil
      else
        "load"
      end
      return row("dry_run", "Would #{action}.", action: action) if dry_run && action
      return row("unchanged", "Already installed and loaded.") unless action
      unload! if changed && loaded
      write(text) if changed
      load!
      outcome = if changed
        existing.nil? ? "installed" : "updated"
      else
        "loaded"
      end
      row(outcome, "The sweep runs every #{INTERVAL / 60} minutes (#{path}).")
    end

    # Unloads the entry and deletes the plist. A failed unload leaves the plist so a retry can finish.
    #
    # @param dry_run [Boolean]
    # @return [Hash{String=>Object}] `outcome` is `removed`, `unchanged` (nothing there) or `dry_run`
    # @raise [Workspace::Error] `sweep_entry_foreign`, `sweep_launchctl_failed`
    def uninstall(dry_run: false)
      refuse_foreign!
      present = File.exist?(path)
      loaded = loaded?
      return row("unchanged", "No sweep entry is installed.") unless present || loaded
      return row("dry_run", "Would unload and delete.", action: "unload and delete") if dry_run
      if loaded
        unload!
      end
      File.delete(path) if present
      row("removed", "The sweep entry is removed.")
    rescue SystemCallError => e
      raise Error.new("Could not remove #{path}: #{e.message}", code: "sweep_launchctl_failed", details: {"plist" => path, "step" => "delete", "output" => e.message})
    end

    # Reads whether the entry is there, ours and loaded. Changes nothing.
    #
    # @return [Hash{String=>Object}] `outcome` is `installed` or `not_installed`, with `installed`, `ours`, `loaded`, `up_to_date`, `stale`, `interval`, `ruby`, `program`
    def status
      existing = read
      ours = existing.nil? ? nil : owned?(existing)
      recorded = (existing && ours) ? recorded_paths(existing) : {}
      stale = recorded.values.compact.reject { |each| File.exist?(each) }
      up_to_date = begin
        (existing && ours) ? existing == plist : nil
      rescue Error
        false
      end
      loaded = begin
        loaded?
      rescue Error
        nil
      end
      message = if existing.nil?
        (loaded == true) ? "No plist is installed, but launchd still has the job loaded; run --uninstall to unload it." : "No sweep entry is installed."
      elsif ours == false
        "A plist is at #{path} that --install did not write."
      elsif loaded.nil?
        "The sweep entry is installed; launchctl could not say whether it is loaded."
      else
        "The sweep entry is installed#{" but not loaded" unless loaded}."
      end
      row((existing.nil? ? "not_installed" : "installed"), message,
        installed: !existing.nil?, ours: ours, loaded: loaded, up_to_date: up_to_date, stale: stale,
        interval: (existing && ours) ? INTERVAL : nil, ruby: recorded["ruby"], program: recorded["program"])
    end

    # @return [String] where the plist lives
    def path
      File.join(@agents_dir, "#{LABEL}.plist")
    end

    private

    def row(outcome, message, **extra)
      {"workspace" => nil, "outcome" => outcome, "reason" => nil, "message" => message, "path" => path, "label" => LABEL}.merge(extra.transform_keys(&:to_s))
    end

    def read
      File.read(path)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError
      ""
    end

    # Ours only when the marker is its own line, the Label key holds our label and the
    # command is `<ruby> <.../bin/workspace> workflow sweep`: text that merely quotes them is not ours.
    def owned?(text)
      return false unless text.lines[2].to_s.chomp == MARKER
      return false unless text.match?(LABEL_LINE)
      block = text[%r{<key>ProgramArguments</key>\s*<array>(.*?)</array>}m, 1]
      return false unless block
      args = strings(block)
      args.size == 4 && args[1].end_with?("/bin/workspace") && args[2..] == %w[workflow sweep]
    end

    def strings(text)
      text.scan(%r{<string>([^<]*)</string>}).flatten.map { |each| each.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", '"').gsub("&apos;", "'").gsub("&amp;", "&") }
    end

    def refuse_foreign!
      text = read
      return if text.nil? || owned?(text)
      raise Error.new("#{path} exists and was not written by `workflow sweep --install`; it is left alone. Move it aside first.",
        code: "sweep_entry_foreign", details: {"path" => path})
    end

    # "Could not find service" is the one answer that means not loaded; a
    # launchctl that cannot run, times out or says anything else is a failure.
    def loaded?
      out, code = run("print", "gui/#{@uid}/#{LABEL}")
      return true if code == 0
      return false if out.to_s.include?("Could not find service")
      raise failure("print", out)
    end

    def load!
      out, code = run("bootstrap", "gui/#{@uid}", path)
      raise failure("bootstrap", out, hint: "Without a login session for this user (an ssh login, say) there is no gui/#{@uid} domain: run it from a Terminal on the Mac.") unless code == 0
    end

    def unload!
      out, code = run("bootout", "gui/#{@uid}/#{LABEL}")
      raise failure("bootout", out) unless code == 0
    end

    def remove_stray_temps
      Dir.glob("#{path}.tmp*").each { |each| File.delete(each) }
    rescue SystemCallError
      nil
    end

    def run(*args)
      @launchctl.call(args)
    rescue SystemCallError => e
      [e.message, nil]
    end

    def failure(step, output, hint: nil)
      text = output.to_s.strip[0, 300]
      written = File.exist?(path)
      Error.new("launchctl #{step} failed: #{text}. #{hint} #{written ? "The plist is written; run the command again to finish." : "Nothing was written."}".squeeze(" "),
        code: "sweep_launchctl_failed", details: {"plist" => path, "step" => step, "output" => text, "plist_written" => written},
        retry_with: {"flags" => [], "destructive" => false})
    end

    def write(text)
      FileUtils.mkdir_p(@agents_dir)
      temp = "#{path}.tmp#{Process.pid}"
      File.write(temp, text)
      File.rename(temp, path)
    rescue SystemCallError => e
      File.delete(temp) if temp && File.exist?(temp)
      raise Error.new("Could not write #{path}: #{e.message}", code: "sweep_launchctl_failed", details: {"plist" => path, "step" => "write", "output" => e.message, "plist_written" => false})
    end

    def stable(file)
      match = %r{\A(.+)/Cellar/([^/]+)/[^/]+/(.+)\z}.match(file)
      return file unless match
      opt = "#{match[1]}/opt/#{match[2]}/#{match[3]}"
      File.exist?(opt) ? opt : file
    end

    def search_path(ruby)
      dirs = [File.dirname(ruby)]
      tmux = @which.call("tmux")
      dirs << File.dirname(stable(tmux)) if tmux
      (dirs + BASE_PATH).uniq.join(":")
    end

    def plist
      ruby = stable(@ruby)
      program = @source.executable
      entries = [
        ["Label", LABEL],
        ["ProgramArguments", [ruby, program, "workflow", "sweep"]],
        ["StartInterval", INTERVAL],
        ["RunAtLoad", false],
        ["ProcessType", "Background"],
        ["StandardOutPath", File::NULL],
        ["StandardErrorPath", File::NULL],
        ["EnvironmentVariables", {"PATH" => search_path(ruby)}]
      ]
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        #{MARKER}
        <plist version="1.0">
        <dict>
        #{entries.map { |key, value| "  <key>#{escape(key)}</key>\n  #{value_xml(value, 1)}" }.join("\n")}
        </dict>
        </plist>
      XML
    end

    def value_xml(value, depth)
      pad = "  " * depth
      case value
      when String then "<string>#{escape(value)}</string>"
      when Integer then "<integer>#{value}</integer>"
      when true then "<true/>"
      when false then "<false/>"
      when Array then "<array>\n#{value.map { |each| "#{pad}  #{value_xml(each, depth + 1)}" }.join("\n")}\n#{pad}</array>"
      when Hash then "<dict>\n#{value.map { |key, each| "#{pad}  <key>#{escape(key)}</key>\n#{pad}  #{value_xml(each, depth + 1)}" }.join("\n")}\n#{pad}</dict>"
      end
    end

    def escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
    end

    def recorded_paths(text)
      args = strings(text[%r{<key>ProgramArguments</key>\s*<array>(.*?)</array>}m, 1].to_s)
      {"ruby" => args[0], "program" => args[1]}
    end
  end
end
