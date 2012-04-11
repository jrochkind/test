require 'cap_git_tools/tasks'

set :application, "testing"
set :repository,  "git@github.com:jrochkind/test.git"
set :branch, "foo"
set :use_sudo, false
set :scm, :git 

set :ssh_options, {:forward_agent => true}
#ssh_options[:forward_agent] = true
#default_run_options[:pty] = true

# Or: `accurev`, `bzr`, `cvs`, `darcs`, `git`, `mercurial`, `perforce`, `subversion` or `none`

role :app, "blacklight.library.jhu.edu"                          # Your HTTP server, Apache/etc

set :deploy_to, "/home/rochkind/tmp/cap-deploy-test"


before "deploy:update", "git:tag"
before "git:tag", "git:guard_committed", "git:guard_upstream" 

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


