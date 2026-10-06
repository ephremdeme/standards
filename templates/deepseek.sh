# Interactive DeepSeek session through Claude Code. Source this file from ~/.zshrc or ~/.bashrc
# (`. /path/to/standards/templates/deepseek.sh`) — never paste a copy: copies drift from the dispatcher.
# Settings apply only inside the subshell. Normal `claude` stays Claude (use it for reviews).
# Effort: max by default (DeepSeek's guide; founder 2026-10-06); `DS_EFFORT=high deepseek` for a lighter session.
deepseek() {
  if [ -z "${DS_API_KEY:-}" ] || [ "$DS_API_KEY" = "your_actual_DS_ai_api_key_here" ]; then
    echo "Error: set DS_API_KEY first." >&2
    return 1
  fi
  (
    unset ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic" \
    ANTHROPIC_AUTH_TOKEN="$DS_API_KEY" \
    ANTHROPIC_MODEL="deepseek-flash[1m]" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-flash[1m]" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-flash[1m]" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-flash" \
    CLAUDE_CODE_SUBAGENT_MODEL="deepseek-flash" \
    CLAUDE_CODE_EFFORT_LEVEL="${DS_EFFORT:-max}" \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    command claude "$@"
  )
}
