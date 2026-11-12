require "digest"
require "fileutils"
require "json"

module Workspace
  # The one writer of a workspace's tmuxinator config: the file is replaced whole through {AtomicFile},
  # and beside it a render record (the sidecar, `<Config#render_state_dir>/<name>.json`) says what it was
  # rendered from: `schema`, `kind`, `template`, `template_sha`, `inputs` and `rendered_sha`, the sha256 of
  # the file as written. A file whose sha256 is not `rendered_sha` was edited by something else.
  class TmuxinatorConfigWriter
    SCHEMA = 1

    # What a sidecar holds, read back: `kind` a Symbol and `inputs` symbol-keyed, so
    # `ProjectConfig#render(record.kind, record.inputs, text)` takes them as they are.
    Record = Data.define(:kind, :template, :template_sha, :inputs, :rendered_sha)

    # @param config [Workspace::Config] for `config_path_for` and `render_state_dir`
    def initialize(config:)
      @config = config
    end

    # Writes a config, then its sidecar.
    #
    # @param name [String] the workspace name
    # @param text [String] the config text
    # @param kind [Symbol] `:project` or `:worktree`
    # @param template [String] the template set's name
    # @param template_sha [String] sha256 of the template text rendered
    # @param inputs [Hash] the render inputs by Symbol (`ProjectConfig#render`'s, plus any recorded beside them,
    #   such as `agent_command`); stored with String keys
    # @return [void]
    # @raise [SystemCallError] when a write fails; the old file is left as it was
    def write(name, text, kind:, template:, template_sha:, inputs:)
      write_config(name, text)
      write_record(name, {
        "schema" => SCHEMA, "kind" => kind.to_s, "template" => template, "template_sha" => template_sha,
        "inputs" => inputs.transform_keys(&:to_s), "rendered_sha" => sha(text)
      })
    end

    # @param name [String] the workspace name
    # @return [Record, nil] the sidecar; nil when it is missing, unreadable, not JSON, not schema 1, any
    #   field is not of its kind, or its `inputs.workspace_name` is not +name+ (a rename stopped part way
    #   leaves no record rather than a wrong one)
    def record(name)
      data = read_record(name)
      return unless data && data["inputs"]["workspace_name"] == name
      Record.new(kind: data["kind"].to_sym, template: data["template"], template_sha: data["template_sha"],
        inputs: data["inputs"].transform_keys(&:to_sym), rendered_sha: data["rendered_sha"])
    end

    # Rewrites a sidecar a rename has moved to +name+ while its inputs still name +from+: the block gives
    # the new inputs, and `rendered_sha` becomes +after+'s when it was +before+'s, so a config edited by
    # hand still reads as edited. A sidecar already carried, or none, is left alone, so a retry can call
    # this again.
    #
    # @param name [String] the workspace's new name, where the sidecar now is
    # @param from [String] the name it had
    # @param before [String] the config text under the old name
    # @param after [String] the config text the rename writes under the new name
    # @yieldparam inputs [Hash] the recorded inputs by Symbol
    # @yieldreturn [Hash] the inputs to record
    # @return [Boolean] whether the sidecar was rewritten
    # @raise [SystemCallError] when the write fails; the sidecar is left as it was
    def carry_record(name, from:, before:, after:)
      data = read_record(name)
      return false unless data && data["inputs"]["workspace_name"] == from
      data["inputs"] = yield(data["inputs"].transform_keys(&:to_sym)).transform_keys(&:to_s)
      data["rendered_sha"] = sha(after) if data["rendered_sha"] == sha(before)
      write_record(name, data)
      true
    end

    # Deletes a workspace's sidecar; one listed under another case of the name is not this workspace's
    # and stays.
    #
    # @param name [String] the workspace name
    # @return [void]
    # @raise [SystemCallError] when the delete fails
    def remove_record(name)
      path = record_path(name)
      dir = File.dirname(path)
      File.delete(path) if Dir.exist?(dir) && Dir.children(dir).include?(File.basename(path))
    end

    # Rewrites a config from its own text, keeping the sidecar in step: its `rendered_sha` becomes the new
    # text's and +inputs+ are merged into its `inputs`. A config with no sidecar is written alone.
    #
    # @param name [String] the workspace name
    # @param inputs [Hash, #call] inputs to merge into the sidecar's, by Symbol; a callable is given the new
    #   text and answers the Hash, so the record follows what was written
    # @yieldparam text [String] the config as it is now
    # @yieldreturn [String, nil] the new text; nil writes nothing
    # @return [String, nil] the text written
    # @raise [SystemCallError] when the config can't be read or a write fails
    def patch(name, inputs: {})
      text = yield File.read(@config.config_path_for(name))
      return unless text
      inputs = inputs.call(text) if inputs.respond_to?(:call)
      write_config(name, text)
      current = record(name)
      return text unless current
      write_record(name, {
        "schema" => SCHEMA, "kind" => current.kind.to_s, "template" => current.template,
        "template_sha" => current.template_sha,
        "inputs" => current.inputs.merge(inputs).transform_keys(&:to_s), "rendered_sha" => sha(text)
      })
      text
    end

    # @param name [String] the workspace name
    # @return [Boolean] whether the config is byte for byte what was last recorded; false with no config or no sidecar
    def current?(name)
      current = record(name)
      !current.nil? && sha(File.read(@config.config_path_for(name))) == current.rendered_sha
    rescue SystemCallError, IOError
      false
    end

    # @param name [String] the workspace name
    # @return [String] path to its sidecar
    def record_path(name)
      File.join(@config.render_state_dir, "#{name}.json")
    end

    private

    KINDS = %w[project worktree].freeze
    private_constant :KINDS

    def read_record(name)
      data = JSON.parse(File.read(record_path(name)))
      data if well_formed?(data)
    rescue SystemCallError, IOError, JSON::ParserError
      nil
    end

    def well_formed?(data)
      data.is_a?(Hash) && data["schema"] == SCHEMA && KINDS.include?(data["kind"]) && data["inputs"].is_a?(Hash) &&
        %w[template template_sha rendered_sha].all? { |key| data[key].is_a?(String) }
    end

    def sha(text)
      Digest::SHA256.hexdigest(text)
    end

    # A config that exists keeps its mode; a new one gets the umask's, as `File.write` gives.
    def write_config(name, text)
      path = @config.config_path_for(name)
      mode = begin
        File.stat(path).mode & 0o7777
      rescue Errno::ENOENT
        nil
      end
      AtomicFile.write(path, text, perm: nil, writer: ->(temp, content) {
        File.open(temp, "w") do |file|
          file.write(content)
          file.flush
          file.fsync
        end
        File.chmod(mode, temp) if mode
      })
    end

    def write_record(name, data)
      FileUtils.mkdir_p(@config.render_state_dir, mode: 0o700)
      AtomicFile.write(record_path(name), "#{JSON.pretty_generate(data)}\n")
    end
  end
end
