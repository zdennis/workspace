require "yaml"
require "json"
require "digest"

module Workspace
  # The `import:` half of a workflow definition: for each step of one file's raw mapping that names a step of a
  # step library, reads that library step and lays the host step's own keys over it. Like {WorkflowExtends} it
  # works on the raw YAML mapping, before {WorkflowDefinition} checks the result, so an imported step is checked
  # as a step the host wrote. An import is a copy, not inheritance: a library step may not import, and nothing of
  # the library is read again later.
  #
  # A step library is a YAML file of `schema_version`, `description` and `steps`. A host step's `import:` is a
  # bare `NAME` (the step `NAME` of `steps/NAME.yml`, found through the injected lookup) or `PATH.yml#NAME` (the
  # step `NAME` of that file, PATH read against the host's directory).
  #
  # Every import that can't be resolved is listed in {#failure}; when there is one, nothing of the file should
  # be checked further, as with {WorkflowExtends#failure}.
  class WorkflowImports
    # The top-level keys a step library may hold.
    LIBRARY_KEYS = %w[schema_version description reviewers steps].freeze

    # Keys a library step may not hold, and why.
    LIBRARY_STEP_REFUSALS = {
      "import" => "a library step can't import another step (imports don't chain)",
      "after" => "a library step can't take after: (the host places the step)",
      "fan_out" => "a library step can't be a fan_out group"
    }.freeze

    # Host keys that place the step rather than change it, so they are never counted as overrides.
    PLACEMENT_KEYS = %w[after].freeze

    FILE_REFERENCE = /\A(?<path>[^\0]+\.yml)#(?<name>[^#]+)\z/

    # The faults of a step library file as a whole: its text, top-level keys, `schema_version`, and each step's
    # shape and refused keys. The one check an import, `workflow validate` on a library and the source installer share.
    #
    # @param text [String] the library file's text
    # @param dir [String, nil] the directory a reviewer's relative `prompt_file` is read against (the library file's)
    # @return [Array<String>] each fault, empty for a good library
    def self.library_problems(text, dir: nil)
      read_library(text, dir: dir).last
    end

    # @param text [String]
    # @param dir [String, nil] the directory a reviewer's relative `prompt_file` is read against; nil only checks it is a path
    # @return [Array(Hash, Hash, Array<String>)] the library's steps (step id to its mapping), its reviewers as written
    #   (name to mapping) and its faults. Reviewers are checked by the rules a workflow's `reviewers:` follow; their
    #   placeholders are left to the host that uses them.
    def self.read_library(text, dir: nil)
      text = text.dup.force_encoding(Encoding::UTF_8)
      return [{}, {}, ["the file is not valid UTF-8 text"]] unless text.valid_encoding?
      raw = YAML.safe_load(text)
      return [{}, {}, ["the file must be a YAML mapping"]] unless raw.is_a?(Hash)
      problems = []
      unknown = raw.keys.map(&:to_s) - LIBRARY_KEYS
      problems << "a step library has unknown key(s) #{unknown.join(", ")} (known: #{LIBRARY_KEYS.join(", ")})" if unknown.any?
      schema = raw.key?("schema_version") && schema_problem(raw, text)
      problems << schema if schema
      reviewers = raw["reviewers"]
      problems.concat(reviewer_problems(reviewers, dir)) if raw.key?("reviewers")
      reviewers = {} unless reviewers.is_a?(Hash)
      steps = raw["steps"]
      unless steps.is_a?(Hash) && steps.any?
        problems << "a step library needs steps: a mapping of step id to step"
        return [{}, reviewers, problems]
      end
      steps.each do |step_id, step|
        unless IdPatterns::WORKFLOW_ID.match?(step_id.to_s)
          problems << "step #{step_id.to_s.inspect[0, 60]}: a step id must be #{IdPatterns::WORKFLOW_ID_RULE}"
          next
        end
        unless step.is_a?(Hash)
          problems << "step #{step_id}: must be a mapping of step keys"
          next
        end
        LIBRARY_STEP_REFUSALS.each { |key, why| problems << "step #{step_id}: #{why}" if step.key?(key) }
      end
      [steps.to_h { |step_id, step| [step_id.to_s, step] }, reviewers.to_h { |name, spec| [name.to_s, spec] }, problems]
    rescue Psych::Exception => e
      [{}, {}, ["the file is not valid YAML (#{e.message.lines.first.to_s.strip})"]]
    end

    # The same `schema_version` rule as a workflow's: `0.1` (as written), legacy `1`, or no key.
    def self.schema_problem(raw, text)
      value = raw["schema_version"]
      written = value.is_a?(Numeric) ? top_scalar_text(text, "schema_version") : value.inspect
      version = case value
      when String then value
      when Float then written
      when Integer then WorkflowDefinition::LEGACY_SCHEMA_VERSIONS[written]
      end
      return nil if WorkflowDefinition::SCHEMA_VERSIONS.include?(version)
      "schema_version must be one of #{WorkflowDefinition::SCHEMA_VERSIONS.join(", ")}, got #{written}"
    end

    def self.top_scalar_text(text, key)
      root = YAML.parse(text)&.root
      return nil unless root.is_a?(Psych::Nodes::Mapping)
      found = root.children.each_slice(2).select { |k, v| k.is_a?(Psych::Nodes::Scalar) && k.value == key && v.is_a?(Psych::Nodes::Scalar) }
      found.last&.last&.value
    end

    # The faults of a library's `reviewers:` by {WorkflowReviewSpec#reviewers}'s rules; its placeholder check does nothing,
    # as the inputs a prompt may use are the host's.
    def self.reviewer_problems(raw, dir)
      found = []
      noop = ->(*_args, **_kwargs) {}
      text = ->(value, where) do
        return nil if value.nil?
        return value if value.is_a?(String) && !value.strip.empty?
        found << "#{where} must be text, got #{value.inspect[0, 60]}"
        nil
      end
      names = ->(value, where) do
        return [] if value.nil?
        return value if value.is_a?(Array) && value.all? { |name| name.is_a?(String) && !name.strip.empty? }
        found << "#{where} must be a list of names, got #{value.inspect[0, 60]}"
        []
      end
      WorkflowReviewSpec.new(
        name_pattern: WorkflowDefinition::INPUT_PATTERN, report: ->(message) {
          found << message
          nil
        },
        prompt: ->(spec, where) { reviewer_prompt(spec, where, dir, found) }, placeholders: noop,
        text: text, names: names, uses: noop, context: noop, duration: noop
      ).reviewers(raw, {})
      found
    end

    def self.reviewer_prompt(spec, where, dir, found)
      if spec.key?("prompt") == spec.key?("prompt_file")
        found << "#{where} needs exactly one of prompt and prompt_file"
        return nil
      end
      if spec.key?("prompt")
        value = spec["prompt"]
        return value if value.is_a?(String) && !value.strip.empty?
        found << "#{where}: prompt must be text, got #{value.nil? ? "nothing" : value.inspect[0, 60]}" unless value.nil?
        return nil
      end
      file = spec["prompt_file"]
      unless file.is_a?(String) && !file.strip.empty?
        found << "#{where}: prompt_file must be a path"
        return nil
      end
      return file unless dir
      full = File.expand_path(file, dir)
      content = File.read(full, encoding: Encoding::UTF_8)
      unless content.valid_encoding?
        found << "#{where}: prompt_file #{full} is not valid UTF-8 text"
        return nil
      end
      found << "#{where}: prompt_file #{full} is empty" if content.strip.empty?
      content
    rescue SystemCallError => e
      found << "#{where}: prompt_file #{full} can't be read (#{e.class})"
      nil
    end
    private_class_method :schema_problem, :top_scalar_text, :reviewer_problems, :reviewer_prompt

    # @return [Array<String>] why an import can't be used, each naming the host step, the reference and the absolute path; empty when every import resolved
    attr_reader :failure

    # @return [Array<Hash{String=>Object}>] one entry per resolved import, in step order: "step" (the host step id),
    #   "import" (the reference as written), "layer" (the layer the lookup found a bare name in; nil for a `PATH#NAME`),
    #   "path" (the library file, absolute), "overrides" (the keys the host set), "removes" (library keys gone from the
    #   result: a `KEY: null`, or a `prompt_file` a `prompt` override replaced, and the reverse), "shadows" (lower-layer
    #   files of the same name the lookup passed over), "sha256" (of the library step as written, as canonical JSON),
    #   "reviewers" (the library reviewers the merged step's `review:` names, which the import added to the host's
    #   `reviewers:`) and "reviewer_overrides" (the names it uses that the host's own `reviewers:` defines, which win);
    #   both are empty when there are none
    attr_reader :imports

    # @return [Array<Hash{String=>String}>] things an import did that are probably a mistake, never an error, in the shape
    #   of {WorkflowExtends#notes}: "code" (`import_dropped`, or `import_not_checked` for a bare name read with no lookup), "step" and "message"
    attr_reader :notes

    # @return [Array<String>] the host steps whose bare-name import was left as written because no lookup was given
    attr_reader :unchecked

    # @param lookup [#call, nil] given a library name and `layer:` (the host's layer), answers a Hash: "path" (the
    #   first `<layer>/steps/NAME.yml` from that layer down, or nil), "layer" (where it was found), "searched" (each
    #   layer tried, in order: "layer" and "path") and "shadows" (the lower-layer files of that name it passed over);
    #   nil means bare names can't be checked here
    # @param layer [String] the host's layer, as the lookup knows it ("project", "global", "source:N", "builtin", "file" or "stdin")
    # @param base_dir [String, nil] the directory a `PATH#NAME` is read against (the host file's directory)
    # @param confine_dir [String, nil] for a source or builtin host: its layer directory; a `PATH#NAME` that is absolute,
    #   starts with `~`, or lands outside it once symlinks are followed is refused
    def initialize(lookup:, layer:, base_dir:, confine_dir: nil)
      @lookup = lookup
      @layer = layer
      @base_dir = base_dir
      @confine_dir = confine_dir
      @failure = []
      @imports = []
      @notes = []
      @unchecked = []
      @libraries = {}
      @nulled = {}
      @brought = {}
    end

    # @param raw [Hash] the definition's YAML mapping
    # @return [Hash] the mapping with each importing step of `steps:` and `replace:` swapped for the library step
    #   with the host's keys laid over it: a host key replaces the library value whole, `KEY: null` removes it, and
    #   `import` itself is dropped; a `fan_out` group and its siblings are left as written for the definition to judge
    def expand(raw)
      expanded = raw.dup
      @host_reviewers = raw["reviewers"]
      @added = {}
      %w[steps replace].each do |key|
        next unless raw[key].is_a?(Hash)
        expanded[key] = raw[key].to_h { |step_id, step| [step_id, expand_step(step_id.to_s, step)] }
      end
      expanded["reviewers"] = (@host_reviewers || {}).merge(@added) if @added.any?
      expanded
    end

    # The words every problem of an imported step ends with, so its author can tell where to look.
    #
    # @param step_id [String]
    # @return [String, nil] "(step imported from REF, PATH; the host sets KEYS)", or nil for a step that wasn't imported
    def provenance(step_id)
      entry = @imports.find { |each| each["step"] == step_id }
      return nil unless entry
      set = entry["overrides"] + @nulled.fetch(step_id, [])
      set.empty? ? "(step imported from #{entry["import"]}, #{entry["path"]})" : "(step imported from #{entry["import"]}, #{entry["path"]}; the host sets #{set.uniq.join(", ")})"
    end

    private

    def expand_step(step_id, step)
      return step unless step.is_a?(Hash) && step.key?("import") && !step.key?("fan_out")
      reference = step["import"]
      found = resolve(step_id, reference)
      return step unless found
      path, layer, shadows = found
      library_step, library_reviewers = library_step(step_id, reference, path)
      return step unless library_step
      merge(step_id, reference, path, layer, shadows, library_step, step.except("import"), library_reviewers)
    end

    # [path, layer, shadows] of the library file a reference names; nil, with {#failure} or {#unchecked} set, when there is none.
    def resolve(step_id, reference)
      if reference.is_a?(String) && IdPatterns::WORKFLOW_ID.match?(reference)
        resolve_name(step_id, reference)
      elsif reference.is_a?(String) && (match = FILE_REFERENCE.match(reference)) && IdPatterns::WORKFLOW_ID.match?(match[:name])
        resolve_file(step_id, reference, match[:path])
      else
        @failure << "step #{step_id}: import must be a step name (#{IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got #{reference.inspect[0, 60]}"
        nil
      end
    end

    def resolve_name(step_id, name)
      unless @lookup
        @unchecked << step_id
        @notes << {"code" => "import_not_checked", "step" => step_id,
                   "message" => "step #{step_id}: import #{name} names a step library that can't be found here, where no workflows are known, so the step is not checked"}
        return nil
      end
      found = @lookup.call(name, layer: @layer) || {}
      return [found["path"], found["layer"], Array(found["shadows"])] if found["path"]
      searched = Array(found["searched"]).map { |each| "#{each["layer"]} #{each["path"]}" }
      @failure << "step #{step_id}: import #{name}: no layer has steps/#{name}.yml (searched: #{searched.empty? ? "none" : searched.join(", ")})"
      nil
    end

    def resolve_file(step_id, reference, written)
      path = File.expand_path(written, @base_dir)
      if @confine_dir && written.start_with?("/", "~")
        @failure << "step #{step_id}: import #{reference} (#{path}): this workflow's imports must be paths inside its own directory #{@confine_dir}, not absolute or ~ paths"
        return nil
      end
      unless File.file?(path)
        @failure << "step #{step_id}: import #{reference}: no file #{path}"
        return nil
      end
      return [path, nil, []] unless @confine_dir
      unless File.directory?(@confine_dir)
        @failure << "step #{step_id}: import #{reference} (#{path}): this workflow's directory #{@confine_dir} is missing, so the import can't be checked"
        return nil
      end
      real = File.realpath(path)
      unless inside?(real, File.realpath(@confine_dir))
        @failure << "step #{step_id}: import #{reference} (#{path}): the file is outside this workflow's directory #{@confine_dir} once links are followed"
        return nil
      end
      # The file checked is the file read, so a link swapped after the check can't point the read elsewhere.
      [real, nil, []]
    end

    def inside?(path, dir)
      path.start_with?(dir.end_with?("/") ? dir : "#{dir}/")
    end

    def library_step(step_id, reference, path)
      steps, reviewers, problems = @libraries[path] ||= read(path)
      if problems.any?
        @failure.concat(problems.map { |problem| "step #{step_id}: import #{reference} (#{path}): #{problem}" })
        return nil
      end
      name = reference.split("#").last
      return [steps[name], reviewers] if steps.key?(name)
      @failure << "step #{step_id}: import #{reference} (#{path}): the file has no step #{name} (its steps: #{steps.keys.join(", ")})"
      nil
    end

    def read(path)
      self.class.read_library(File.read(path), dir: File.dirname(path))
    rescue SystemCallError => e
      [{}, {}, ["the file can't be read (#{e.message})"]]
    end

    def merge(step_id, reference, path, layer, shadows, library_step, own, library_reviewers)
      base = deep_copy(library_step)
      base["prompt_file"] = File.expand_path(base["prompt_file"], File.dirname(path)) if base["prompt_file"].is_a?(String)
      nulled = own.select { |_, value| value.nil? }.keys.map(&:to_s)
      overrides = own.keys.map(&:to_s) - nulled - PLACEMENT_KEYS
      removes = nulled.select { |key| base.key?(key) }
      removes << "prompt_file" if overrides.include?("prompt") && !overrides.include?("prompt_file") && base.key?("prompt_file")
      removes << "prompt" if overrides.include?("prompt_file") && !overrides.include?("prompt") && base.key?("prompt")
      note_dropped(step_id, reference, library_step, own, nulled)
      @nulled[step_id] = nulled
      merged = base.except(*removes).merge(own.reject { |_, value| value.nil? })
      brought, overridden = bring_reviewers(step_id, reference, path, merged, library_reviewers)
      @imports << {"step" => step_id, "import" => reference, "layer" => layer, "path" => path,
                   "overrides" => overrides, "removes" => removes, "shadows" => shadows,
                   "sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(library_step))),
                   "reviewers" => brought, "reviewer_overrides" => overridden}
      merged
    end

    # Adds the library reviewers the merged step's `review:` names to the host's raw `reviewers`; returns the names
    # brought in and the names the host defined itself. A host `reviewers:` that is not a mapping is left for build to report.
    def bring_reviewers(step_id, reference, path, merged, library_reviewers)
      brought = []
      overridden = []
      return [brought, overridden] unless @host_reviewers.nil? || @host_reviewers.is_a?(Hash)
      review_names(merged["review"]).uniq.each do |name|
        if @host_reviewers&.keys&.any? { |key| key.to_s == name }
          overridden << name if library_reviewers.key?(name)
          next
        end
        next unless library_reviewers.key?(name)
        entry = deep_copy(library_reviewers[name])
        entry["prompt_file"] = File.expand_path(entry["prompt_file"], File.dirname(path)) if entry.is_a?(Hash) && entry["prompt_file"].is_a?(String)
        if clash?(step_id, reference, path, name, entry)
          next
        end
        @added[name] = entry
        brought << name
      end
      [brought, overridden]
    end

    def clash?(step_id, reference, path, name, entry)
      earlier_path, earlier = @brought[name]
      if earlier_path.nil?
        @brought[name] = [path, canonical(entry)]
        return false
      end
      return false if earlier == canonical(entry)
      @failure << "step #{step_id}: import #{reference} (#{path}): reviewer #{name} is also brought in by #{earlier_path} with different content"
      true
    end

    def review_names(review)
      names = review.is_a?(Hash) ? review["from"] : review
      names.is_a?(Array) ? names.select { |name| name.is_a?(String) } : []
    end

    def note_dropped(step_id, reference, library_step, own, nulled)
      nulled.each do |key|
        next unless library_step.key?(key)
        dropped(step_id, "step #{step_id}: #{key}: null removes the #{key} of imported step #{reference} (#{brief(library_step[key])})")
      end
      own.each do |key, value|
        old = library_step[key.to_s]
        lost = if old.is_a?(Array) && value.is_a?(Array)
          old - value
        elsif old.is_a?(Hash) && value.is_a?(Hash)
          old.keys - value.keys
        else
          []
        end
        next if lost.empty?
        dropped(step_id, "step #{step_id}: #{key} replaces the #{key} of imported step #{reference} whole and drops #{lost.map { |each| brief(each) }.join(", ")}")
      end
    end

    def dropped(step_id, message)
      @notes << {"code" => "import_dropped", "step" => step_id, "message" => message}
    end

    def brief(value)
      value.is_a?(String) ? value[0, 60] : JSON.generate(value)[0, 60]
    end

    def canonical(value)
      case value
      when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, each| [key.to_s, canonical(each)] }
      when Array then value.map { |each| canonical(each) }
      else value
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
