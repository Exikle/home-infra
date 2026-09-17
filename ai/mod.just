# Agent tooling — lint and evaluate this repo's own agent config

[private]
default:
    @just --list ai

# Audit the agent config — symlinks, frontmatter, @imports, the reference index
[group('ai')]
lint-agents:
    @python3 "{{ justfile_directory() }}/scripts/check-agent-config.py"

# Behavioural tests for the instruction set — costs tokens, so on demand, never in a hook
[group('ai')]
eval *ARGS:
    @python3 "{{ justfile_directory() }}/scripts/eval-instructions.py" {{ ARGS }}
