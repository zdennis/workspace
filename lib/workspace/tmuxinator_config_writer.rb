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
    # `approx` is false unless the record was adopted from a config a render does not reproduce.
    Record = Data.define(:kind, :template, :template_sha, :inputs, :rendered_sha, :approx) do
      def initialize(approx: false, **fields)
        super
      end
    end

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
      write_record_for(name, text, kind: kind, template: template, template_sha: template_sha, inputs: inputs)
    end

    # Writes only the sidecar of a config that already holds +text+, leaving the config's bytes and mtime
    # alone: `template apply` when another set renders the same text.
    #
    # @param name [String] the workspace name
    # @param text [String] the config text the record describes
    # @param kind [Symbol] see {#write}
    # @param template [String] see {#write}
    # @param template_sha [String] see {#write}
    # @param inputs [Hash] see {#write}
    # @param approx [Boolean] the config does not hold +text+ (`template adopt` found no exact render): +text+ is
    #   what a render writes, its sha256 is recorded, so the file reads as edited, and the record says `approx`
    # @return [void]
    # @raise [SystemCallError] when the write fails; the sidecar is left as it was
    def write_record_for(name, text, kind:, template:, template_sha:, inputs:, approx: false)
      data = {
        "schema" => SCHEMA, "kind" => kind.to_s, "template" => template, "template_sha" => template_sha,
        "inputs" => inputs.transform_keys(&:to_s), "rendered_sha" => sha(text)
      }
      data["approx"] = true if approx
      write_record(name, data)
    end

    # @param name [String] the workspace name
    # @return [Record, nil] the sidecar; nil when it is missing, unreadable, not JSON, not schema 1, any
    #   field is not of its kind, or its `inputs.workspace_name` is not +name+ (a rename stopped part way
    #   leaves no record rather than a wrong one)
    def record(name)
      data = read_record(name)
      return unless data && data["inputs"]["workspace_name"] == name
      Record.new(kind: data["kind"].to_sym, template: data["template"], template_sha: data["template_sha"],
        inputs: data["inputs"].transform_keys(&:to_sym), rendered_sha: data["rendered_sha"], approx: data["approx"] == true)
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
    # @param keep_sha [Boolean, #call] true (or a callable given the new text that answers true) writes the config and
    #   leaves the sidecar as it is, so the file reads as edited: for a change the render inputs can't reproduce.
    #   A config that was already edited (not at the record's `rendered_sha` before the patch) keeps its sidecar too.
    # @yieldparam text [String] the config as it is now
    # @yieldreturn [String, nil] the new text; nil writes nothing
    # @return [String, nil] the text written
    # @raise [SystemCallError] when the config can't be read or a write fails
    def patch(name, inputs: {}, keep_sha: false)
      before = File.read(@config.config_path_for(name))
      text = yield before
      return unless text
      keep_sha = keep_sha.call(text) if keep_sha.respond_to?(:call)
      keep_sha ||= !was_rendered?(name, before)
      inputs = inputs.call(text) if !keep_sha && inputs.respond_to?(:call)
      write_config(name, text)
      return text if keep_sha
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

    # Puts a config's bytes at its path by the rule {#write} uses: an existing file keeps its own mode (set
    # with an explicit chmod, so the umask can't narrow it), a new one gets the umask's. For a backup put back.
    #
    # @param name [String] the workspace
    # @param bytes [String]
    # @return [void]
    def put_config(name, bytes)
      write_config(name, bytes)
    end

    # Puts a render record's bytes at its path: an existing record keeps its mode, a new one is 0600 as
    # {#write_record} makes it.
    #
    # @param name [String] the workspace
    # @param bytes [String]
    # @return [void]
    def put_record(name, bytes)
      path = record_path(name)
      FileUtils.mkdir_p(@config.render_state_dir, mode: 0o700)
      mode = begin
        File.stat(path).mode & 0o7777
      rescue Errno::ENOENT
        nil
      end
      AtomicFile.write(path, bytes)
      File.chmod(mode, path) if mode
    end

    private

    # Whether +text+, the config as it was, is what the record says was last rendered.
    def was_rendered?(name, text)
      current = record(name)
      !current.nil? && sha(text) == current.rendered_sha
    end

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
      FileUtils.mkdir_p(File.dirname(path))
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
