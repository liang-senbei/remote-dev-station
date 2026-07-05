# ===== Shell 增强（仅交互式：自动建议/语法高亮/模糊搜索/提示符）=====
if [[ $- == *i* ]]; then
  export FZF_DEFAULT_OPTS="--layout=reverse --border=rounded --info=inline-right --pointer=▶ --marker=✓ --color=fg:#908caa,hl:#ebbcba,fg+:#e0def4,bg+:#26233a,hl+:#f6c177,border:#c4a7e7,header:#9ccfd8,info:#6e6a86,pointer:#eb6f92,marker:#9ccfd8,prompt:#c4a7e7,spinner:#f6c177,separator:#403d52,label:#c4a7e7"
  [ -f ~/.local/share/blesh/ble.sh ] && source ~/.local/share/blesh/ble.sh --noattach
  command -v starship >/dev/null && eval "$(starship init bash)"
  [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
  [ -f /usr/share/bash-completion/completions/fzf ] && source /usr/share/bash-completion/completions/fzf
  [ -n "${BLE_VERSION-}" ] && ble-attach
fi
