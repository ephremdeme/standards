# Interactive DeepSeek session through Claude Code. Source from ~/.zshrc or ~/.bashrc.
# Settings apply only inside the subshell. Normal `claude` stays Claude (use it for reviews).
deepseek() {
  if [ -z "${DS_API_KEY:-}" ]; then
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
    CLAUDE_CODE_EFFORT_LEVEL="${DS_EFFORT:-high}" \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    command claude "$@"
  )
}
