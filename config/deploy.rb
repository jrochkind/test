set :application, "testing"
set :repository,  "git@github.com:jrochkind/test.git"

set :scm, :git
# Or: `accurev`, `bzr`, `cvs`, `darcs`, `git`, `mercurial`, `perforce`, `subversion` or `none`

role :web, "blacklight.library.jhu.edu"                          # Your HTTP server, Apache/etc

# if you're still using the script/reaper helper you will need
# these http://github.com/rails/irs_process_scripts

# If you are using Passenger mod_rails uncomment this:
# namespace :deploy do
#   task :start do ; end
#   task :stop do ; end
#   task :restart, :roles => :app, :except => { :no_release => true } do
#     run "#{try_sudo} touch #{File.join(current_path,'tmp','restart.txt')}"
#   end
# end

namespace :git do
  ####
  # Some functions used by the tasks
  #
  
  # say with an indent in spaces
  def say_formatted(msg, options = {})
    options.merge!(:indent => 4)
    Capistrano::CLI.ui.say(' ' * options[:indent] + msg )
  end
  
  # execute a 'git fetch', but mark in a private variable that
  # we have, so we only do it once per cap execution. 
  def ensure_git_fetch
    unless @__git_fetched      
      local_sh "git fetch #{upstream_remote}"
      @__git_fetched = true
    end
  end
  
  # execute locally as a shell command, echo'ing to output, as
  # well as capturing error and aborting. 
  def local_sh(cmd)
    say_formatted("local execute: #{cmd}")
    `#{cmd}`
    abort("failed: #{cmd}") unless $? == 0
  end
  
  # Get :upstream_remote with default
  def upstream_remote
    fetch(:upstream_remote, "origin")
  end
  

  # what branch we're going to tag and deploy -- if cap 'branch' is set,
  # use that one, otherwise use current branch in checkout
  def working_branch
    @__git_working_branch ||= begin
      if exists?("branch")
        fetch(:branch)
      else
        b = `git symbolic-ref -q HEAD`.sub(%r{^refs/heads/}, '').chomp
        b.empty? ? "HEAD" : b
      end
    end
    
  end
  
  # current SHA fingerprint of local branch mentioned in :branch
  def local_sha
    `git log --pretty=format:%H #{working_branch} -1`.chomp
  end
  
  def tag_prefix
    fetch(:tag_prefix, fetch(:stage, "deploy"))
  end
  
  def from_prefix
    fetch("from_prefix", "staging")
  end

  
  # mostly used by git:retag, calculate the tag we'll be retagging FROM. 
  #
  # can set cap :from_tag. Or else find last tag matching from_prefix,
  # which by default is "staging-*"
  def from_tag
    t = nil
    if exists?("from_tag")
      t = fetch("from_tag")
    else
      t = fetch_last_tag(  self.from_prefix ) 
    
      if t.nil? || t.empty?
        abort("failed: can't find existing tag matching #{self.from_prefix}-*")
      end
    end
    return t
  end
  
  # find the last (chronological) tag with given prefix. 
  # prefix can include shell-style wildcards like '*'. Defaults to
  # last tag with current default tag_prefix. 
  #
  # Note: Will only work on git 'full' annotated tags (those signed or 
  # with -m message or -a) because git only stores dates for annotated tags.
  # others will end up sorted lexicographically BEFORE any annotated tags. 
  def fetch_last_tag(pattern_prefix = self.tag_prefix)
    # make sure we've fetched to get latest from upstream. 
    ensure_git_fetch
    
    # crazy git command, yeah. 
    last_tag = `git for-each-ref --sort='taggerdate' --format='%(refname:short)' 'refs/tags/#{pattern_prefix}-*' 2>/dev/null | tail -1 `.chomp
    return nil if last_tag == ''
    return last_tag
  end
  
  # show commit lot from commit-ish to commit-ish,
  # using appropriate UI tool. 
  #
  # If you have cap :github_browser_compare set and the remote is github,
  # use `open` to open in browser. 
  #
  # else if you have ENV['git_log_command'] set, pass to `git` (don't know
  # what this is for, inherited from gitflow)
  #
  # else just use an ordinary command line git log   
  def show_commit_log(from_tag, to_tag)
    if fetch("github_browser_compare", false ) && `git config remote.#{upstream_remote}.url` =~ /git@github.com:(.*)\/(.*).git/      
      # be awesome for github, use `open` in browser
      command = "open https://github.com/#{$1}/#{$2}/compare/#{from_tag}...#{to_tag}"
    elsif ENV['git_log_command'] && ENV['git_log_command'].strip != ''
      # use custom compare command if set
      command = "git #{ENV['git_log_command']} #{from_tag}..#{to_tag}"
    else
      # standard git log command
      command = "git log #{from_tag}..#{to_tag}"      
    end
    
    say_formatted "Displaying commits from #{from_tag} to #{to_tag}\n\n"
    local_sh command
    puts "" # newline
  end
    
  
  def calculate_new_tag
    # if capistrano :tag is already set, just use it        
    if exists?("tag")
      return fetch("tag")
    end
    
    # otherwise calculate, based on template
          
    tag_suffix = fetch("tag_template", "%{datetime}")
      
    tag_suffix.gsub!(/\%\{([^}]+)\}/) do 
      case $1
      when 'date'
        Time.now.localtime.strftime('%Y-%m-%d')
      when 'datetime'
        Time.now.localtime.strftime('%Y-%m-%d-%H%M')
      when 'what'
        (@__git_what = Capistrano::CLI.ui.ask("What does this release introduce? (this will be normalized and used in the tag for this release) ").gsub(/[ '"]+/, "_"))
      when 'who'
        `whoami`.chomp
      end
    end
      
    return "#{tag_prefix}-#{tag_suffix}"    
  end
  
  # will prompt to confirm new tag, if :confirm_retag is true, otherwise
  # no-op. 
  def guard_confirm_tag(new_tag)    
    if exists?("confirm_retag") && [true, "true"].include?(fetch("confirm_retag"))      
      confirmed = Capistrano::CLI.ui.agree("Do you really want to deploy #{new_tag}?") do |q|
        q.default = "no"
      end
      unless confirmed
        abort("exiting, user cancelled.")
      end
    end
  end
  

  # Make sure git working copy has no uncommitted changes,
  # AND current branch in working copy is branch set in cap :branch (if set),
  # or abort commit. 
  task :guard_committed do
    if [true, "true"].include? fetch("skip_guard_committed", false)
      say_formatted("Skipping git:guard_committed")
    else  
      if exists?("branch")
        working_branch = `git symbolic-ref -q HEAD`.sub(%r{^refs/heads/}, '').chomp
        unless fetch("branch") == working_branch
          abort %Q{failed: guard_clean: wrong branch
  
      You have configured to deploy from branch ::#{fetch("branch")}::
      but your git working copy is on branch ::#{working_branch}::
  
          git checkout #{fetch("branch")}
  
      and try again. Or, to skip this check, execute cap again with:
          
          -s skip_guard_committed=true    
          }
        end
      end
      
      # cribbed from bundle release rake task
      `git diff HEAD --exit-code` 
      return_code = $?.to_i
      if return_code == 0
        say_formatted("guard_clean: passed")
      else
        abort %Q{failed: guard_clean: uncomitted changes
  
  There are files that need to be committed first.
      
  Or, to skip this check, execute cap again with:        
     -s skip_guard_committed=true  
        }
      end
    end
  end

  # Make sure local repo has been pushed to upstream, or abort cap
  #
  # * Assumes upstream remote is 'origin', or set :upstream_remote
  # * Looks in :branch (default 'master') to see what branch should be checked,
  #   Assumes local :branch tracks upstream_remote/branch
  #
  #
  # setting cap :skip_guard_upstream will skip even if task is invoked. 
  task :guard_upstream do   
    if [true, "true"].include? fetch("skip_guard_upstream", false)
      say_formatted("Skipping git:guard_upstream")
    else      

      ensure_git_fetch
      
      remote_sha = `git log --pretty=format:%H #{upstream_remote}/#{working_branch} -1`.chomp
      
      unless local_sha == remote_sha
        abort %Q{failed:
  Your local #{working_branch} branch is not up to date with #{upstream_remote}/#{working_branch}.
  This will likely result in deploying something other than you expect.
  
  Please make sure you have pulled and pushed all code before deploying:
  
      git pull #{upstream_remote} #{working_branch}
      # run tests, etc
      git push #{upstream_remote} #{working_branch}
  
  Or, to skip this check run cap again with `-s skip_guard_upstream=true`
        }
      end
      
      say_formatted("guard_upstream: passed")
    end
  end
  
  # Tags the current checkout and pushes tag to remote. 
  # * tag will be prefix-timestamp
  #   * if using multi-stage or otherwise setting :stage, prefix defaults
  #     to :stage   
  #   * otherwise prefix defaults to 'deploy'
  #   * or set explicitly with :tag_prefix
  #
  #  sets :branch to the new tag, so subsequent cap deploy tasks will use it
  #
  #  pushes new tag to 'origin' or cap :upstream_remote
  task :tag do    
    
    # make sure we have any other deployment tags that have been pushed by
    # others so our auto-increment code doesn't create conflicting tags
    ensure_git_fetch

    tag = calculate_new_tag
    
    commit_msg = @__git_what || "cap git:tag: #{tag}"
    
    # tag 'working_branch', means :branch if set, otherwise
    # current working directory checkout. 
    local_sh "git tag -a -m '#{commit_msg}' #{tag} #{self.working_branch}"

    # Push new tag back to origin
    local_sh "git push #{upstream_remote} #{tag}"
    
    # set :branch to tag, so cap will continue on to deploy the tag we just created!    
    set(:branch, tag)
  end
  
  # takes an already existing tag, and retags it and deploys that tag.
  #
  # usually used in git multistage for moving from staging to production
  #
  # * by default, retags latest already existing tag beginning "staging-". 
  #   * set :from_tag for exact tag (or other commit-ish thing) to re-tag
  #     and deploy 
  #   * set :from_prefix to instead lookup last tag with that prefix,
  #     and re-tag and deploy that one.
  # * by default, sets new tag using the same default rules at git:tag,
  #   ie, set :tag, or will calculate using :tag_prefix, or current stage, or 
  #   'deploy' + timestamp or tag_suffix template 
  #
  #  sets :branch to the new tag, so subsequent cap deploy tasks will use it
  #
  #  pushes new tag to 'origin' or cap :upstream_remote
  task :retag do
    from_tag = self.from_tag
    
    to_tag = calculate_new_tag
    
    self.guard_confirm_tag(from_tag)
    
    say_formatted("git:retag taking #{from_tag} and retagging as #{to_tag}")
    
    local_sh "git tag -a -m 'tagging #{from_tag} for deployment as #{to_tag}' #{to_tag} #{from_tag}"
    
    # Push new tag back to origin
    local_sh "git push #{upstream_remote} #{to_tag}"
      
    set(:branch, to_tag)
  end
  
  # Show 5 most recent tags, oldest first 
  #    matching tag_prefix pattern, with some git info about those tags. 
  #
  # tag_prefix defaults to cap :stage, or "deploy-", or set in cap :tag_prefix
  #
  # in newer versions of git you could prob do this with a git-log instead with
  # certain arguments, but my version doesn't support --tags arg properly yet. 
  task :show_tags do    
    system "git for-each-ref --count=5 --sort='taggerdate' --format='\n* %(refname:short)\n    Tagger: %(taggeremail)\n    Date: %(taggerdate)\n\n    %(subject)' 'refs/tags/#{tag_prefix}-*' "
  end
  

  # less flexible than most of our other tasks, assumes certain workflow. 
  # if you're in multi-stage and stage :production, then commit log
  # between last production-* tag and last staging-* tag. 
  #
  # otherwise (for 'staging' or non-multistage) from current branch to
  # last staging tag. 
  #
  # This gets confusing so abstract with all our config, may do odd
  # things with custom config, not sure. 
  task :commit_log do
    from, to = nil, nil
    
    if exists?("stage") && stage.to_s == "production"
      from =  from_tag # last staging-* tag, or last :from_prefix tag
      to = fetch_last_tag # last deploy-* tag, or last :tag_prefix tag
    else
      from = fetch_last_tag # last deploy-* tag, or last :tag_prefix tag
      to = local_sha.slice(0,8)
    end
    
    show_commit_log(from, to)
  end
  
  
  
end

