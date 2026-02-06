if status is-interactive
# Commands to run in interactive sessions can go here
end

set -g fish_greeting

export ANTHROPIC_AUTH_TOKEN="sk-fly-tvuJNQAmdO9xzq3XWfSRNCiKtczmibbfCzzcQ4z46tqBRzIU"
export ANTHROPIC_BASE_URL="https://api.llmgate.dev"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

alias bcubc='brew upgrade --cask && brew cleanup'
alias commit='aicommit -ayp'
alias ncdu='ncdu --exclude ~/Projects'
alias code='code-insiders'
alias copilot='copilot --allow-all-tools'
alias claude='claude --dangerously-skip-permissions'

zoxide init --cmd cd fish | source
starship init fish | source

# bun
set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"
