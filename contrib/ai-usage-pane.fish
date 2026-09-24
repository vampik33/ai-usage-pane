# Starts ai-usage-pane when a shell's prompt arrives in the marker directory.
# Warp restores each pane's size and cwd after a restart, but not the command
# that was running in it, so this brings the usage pane back.
# Install: copy to ~/.config/fish/conf.d/ and `mkdir -p ~/.local/share/ai-usage-pane`.
status is-interactive; or exit

set -g __ai_usage_pane_dir $HOME/.local/share/ai-usage-pane

function __ai_usage_pane_autostart --on-event fish_prompt
    set -l prev $__ai_usage_pane_prev_pwd
    set -g __ai_usage_pane_prev_pwd $PWD
    # Only on arrival, so quitting with `q` leaves a normal prompt.
    test "$PWD" = "$__ai_usage_pane_dir"; and test "$prev" != "$__ai_usage_pane_dir"; or return
    ai-usage-pane
end

function aiu --description 'Turn this pane into the AI usage pane'
    if test "$PWD" = "$__ai_usage_pane_dir"
        ai-usage-pane
    else
        cd $__ai_usage_pane_dir
    end
end
