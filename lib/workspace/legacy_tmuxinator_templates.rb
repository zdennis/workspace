require "digest"

module Workspace
  # The copies of the shipped tmuxinator templates that `workspace init` put in
  # `~/.config/tmuxinator/`, and every version of them workspace ever shipped. A copy whose
  # sha256 is one of {SHIPPED_SHAS} is stock (`init` copies the file byte for byte), so only
  # an edited copy makes {Library#tmuxinator_template} keep rendering from it.
  #
  # {SHIPPED_SHAS} is frozen here and rebuilt by hand when the shipped set changes. The
  # shipped files moved from `project-template.yml` to
  # `lib/templates/workspace.project-template.yml` and then (`git mv`, history kept) to
  # `lib/library/template/default/project.yml` (and likewise `project-worktree-template.yml`,
  # `lib/templates/workspace.project-worktree-template.yml`, `worktree.yml`), so this lists
  # the sha256 of the file at every commit that touched it, repeats removed:
  #
  #   git log --follow --format='C %H' --name-only -- lib/library/template/default/project.yml |
  #     awk '/^C /{c=$2;next} NF{print c, $0}' |
  #     while read c p; do git show "$c:$p" | shasum -a 256; done | sort -u
  #
  # (`worktree.yml` for the worktree kind). That reaches the placeholder text of
  # `fb23a5e7` (`{{AGENT_COMMAND}}`) and every version before it: 10 distinct shas per kind
  # (11 versions, one shipped twice).
  module LegacyTmuxinatorTemplates
    # The installed copy's file name in the tmuxinator directory, by kind.
    FILES = {
      project: "workspace.project-template.yml",
      worktree: "workspace.project-worktree-template.yml"
    }.freeze

    # sha256 of every shipped version, by kind.
    SHIPPED_SHAS = {
      project: %w[
        6b017acccfc4e0f9338d077f8969c441e0c09af268d4fba6afdfb2cc27727953
        e785588750652dabeb9dbbe3cc88515c2cc8b2c5cc4d0dc8c4cc5a773444b5f9
        5a9ee4d47e7c35a5c223a5fac49fa67eed328de8bbaae54336a1ee9b351bcd33
        d3814ed363d4f40d89ec0cb8e50fa1daf9f786984603deff3305a8a465ba50e7
        c1ac32fd94b23ebf9195ee19564d1c284bdc978c6d68aae130de273d02fb14db
        dd699de869e6390604aa00a77f99ac3b26e452a7a79147818ab2838fe9064d50
        8c848c7c85536515bf1b41adf939556f919fe7a4c22db27547db34864db40f48
        ff597ba9fd3c93a38416ae7c817817c5e4cb904ad169f1e449e259d05a463760
        0b5efefe1494de69fbdeef91502ea65e20cb6a889cc3e6c352be0a6b8a083cc2
        453769f1af39e3f7e418dcf870b11ad300d599d5391ed8c8f2098396a10c90ce
      ].freeze,
      worktree: %w[
        613ce1195cff525e0bd8c049285c55371e2203d25b1023e75fffaaa2d10297cd
        b5eedbfcd90c406870a51dafac07a30575e878be0bd86e8f6a4389a607892782
        d216f83a0dbace9da4c1478c5b1f23cfe12b298d3e23f00e5d8b25921811351e
        c2d76ef90e98c0eac16b2b970b201de80ce9468a1af61d8f6db0bf6f3e0125d1
        fee5e8e5e78107962b8d337ee33652437eb34bbe8980b505a67cd7fd6dad48f7
        d9e089fd54cd018dec3b11458fd424707b65ac0b7ff3510eac17d81339c11b08
        3ff9180ee1bcfc2a9edab1262e6891da1e5b3b86a4e6d54090c5f19bbe7b0f59
        7da167b6fde11a458fa000e246c94d153707588d472f31abfc4d605d2e1e9ccc
        a67691c829b2c7ecd64c4c0b7707efab7f13b86fcbfed2041f1a2a0e19a6596e
        1cb68a72faeedcc16d79ceca1979af46ec408e1c086d76cff97c089258182251
      ].freeze
    }.freeze

    # @param kind [Symbol] `:project` or `:worktree`
    # @param tmuxinator_dir [String]
    # @return [String] where `init` put that kind's copy
    def self.path(kind, tmuxinator_dir)
      File.join(tmuxinator_dir, FILES.fetch(kind))
    end

    # @param kind [Symbol] `:project` or `:worktree`
    # @param path [String] an installed copy
    # @return [Boolean] whether the file exists and is not byte for byte a version workspace shipped;
    #   a file that can't be read counts as not edited
    def self.edited?(kind, path)
      return false unless File.file?(path)
      !SHIPPED_SHAS.fetch(kind).include?(Digest::SHA256.file(path).hexdigest)
    rescue SystemCallError
      false
    end
  end
end
