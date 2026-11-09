require "ripper"

# Spec tooling for the dependency-direction guard. Reads Ruby source as text
# (no process, no load) and reports which constants each file references and
# which file defines each constant.
#
# References are found from Ripper's tokens, so a name inside a comment, an
# =begin block or the text of a string is never seen. Code inside a string
# interpolation (the #{} part) is code and does count.
#
# Matching is by directory (Reference#target_files, BoundaryScan.under?) and by
# qualified name (Reference#constant is the chain as written, "Commands::Inbox").
# There is no prefix-of-file-name mode.
class BoundaryScan
  Reference = Struct.new(:file, :line, :constant, :target_files, keyword_init: true)

  BLANKED = %i[on_comment on_embdoc_beg on_embdoc on_embdoc_end on_tstring_content].freeze

  # The source with comments and string text replaced by spaces; newlines stay,
  # so line and column positions are unchanged.
  def self.strip(source)
    Ripper.lex(source).map { |_pos, type, text, _state|
      BLANKED.include?(type) ? text.gsub(/[^\n]/, " ") : text
    }.join
  end

  # Each constant chain a source references as [line, "A::B"]. The name in a
  # `class`/`module` header is included; the caller drops its own file.
  def self.chains(source)
    found = []
    current = nil
    Ripper.lex(source).each do |(line, _col), type, text, _state|
      if type == :on_const
        if current && current[:open]
          current[:parts] << text
          current[:open] = false
        else
          found << current if current
          current = {line: line, parts: [text], open: false}
        end
      elsif type == :on_op && text == "::" && current && !current[:open]
        current[:open] = true
      elsif type == :on_sp || type == :on_ignored_nl
        next
      else
        found << current if current
        current = nil
      end
    end
    found << current if current
    found.map { |c| [c[:line], c[:parts].join("::")] }
  end

  # Qualified names a source defines: class, module and constant assignment,
  # each under its enclosing class or module.
  def self.definitions(source)
    names = []
    walk(Ripper.sexp(source), [], names)
    names
  end

  def self.walk(node, scope, names)
    return unless node.is_a?(Array)

    case node[0]
    when :class, :module
      name = path_of(node[1])
      if name
        names << (scope + [name]).join("::")
        walk(node[2], scope + [name], names) if node[0] == :module
        walk(node[3], scope + [name], names) if node[0] == :class
        return
      end
    when :assign
      target = node[1]
      if target.is_a?(Array) && target[0] == :var_field && target[1].is_a?(Array) && target[1][0] == :@const
        names << (scope + [target[1][1]]).join("::")
      end
    end
    node.each { |child| walk(child, scope, names) if child.is_a?(Array) }
  end

  def self.path_of(node)
    return nil unless node.is_a?(Array)

    case node[0]
    when :const_ref, :var_ref then node[1].is_a?(Array) ? node[1][1] : nil
    when :const_path_ref then [path_of(node[1]), node[2][1]].compact.join("::")
    when :top_const_ref then node[1][1]
    end
  end

  # True when the repo-relative path is the directory (a trailing "/") or the file.
  def self.under?(file, location)
    location.end_with?("/") ? file.start_with?(location) : file == location
  end

  # root: the repo root. paths: repo-relative files to read (default lib/**/*.rb).
  def initialize(root, paths: nil)
    @root = root
    @paths = paths || Dir.glob("lib/**/*.rb", base: root).sort
  end

  # name (as qualified in source) => files that define it
  def definitions
    @definitions ||= sources.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(file, source), table|
      self.class.definitions(source).each { |name| table[name] << file }
    end
  end

  # Names defined in more than one file, with the files; references to them
  # have no target and are listed here instead.
  def ambiguous
    definitions.select { |_name, files| files.uniq.size > 1 }.transform_values(&:uniq)
  end

  # Every constant reference in the scanned files whose chain, or its longest
  # leading part, names something defined in lib/. Same-file hits are left out.
  def references
    @references ||= sources.flat_map { |file, source|
      self.class.chains(source).filter_map do |line, chain|
        targets = resolve(chain) - [file]
        next if targets.empty?

        Reference.new(file: file, line: line, constant: chain, target_files: targets)
      end
    }
  end

  def references_from(location)
    references.select { |ref| self.class.under?(ref.file, location) }
  end

  private

  def sources
    @sources ||= @paths.to_h { |path| [path, File.read(File.join(@root, path), encoding: "UTF-8")] }
  end

  def resolve(chain)
    parts = chain.split("::")
    parts.size.downto(1) do |size|
      files = files_for(parts.first(size).join("::"))
      return files unless files.empty?
    end
    []
  end

  # A name written "Inbox" or "Commands::Inbox" matches the definition whose
  # qualified name ends with it; a name with several defining files is ambiguous.
  def files_for(name)
    @by_suffix ||= {}
    @by_suffix[name] ||= begin
      matches = definitions.select { |full, _| full == name || full.end_with?("::#{name}") }
      files = matches.values.flatten.uniq
      (matches.size == 1 && files.size == 1) ? files : []
    end
  end
end
