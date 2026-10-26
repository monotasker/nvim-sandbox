# GitHub repository settings

Apply once the remote exists (`git remote add origin …` and first push). These
are GitHub **settings**, not tracked files — run from a machine with `gh` auth:

```bash
gh repo edit monotasker/nvim-sandbox \
  --description "Reusable Neovim editor container: Fedora floor, seed-on-boot home, manifest configs, optional personal addon." \
  --homepage "" \
  --add-topic neovim \
  --add-topic docker \
  --add-topic nvim \
  --add-topic dotfiles \
  --add-topic tmux \
  --add-topic zsh \
  --add-topic devcontainer
```

Suggested About blurb (same as `--description` above):

> Reusable Neovim editor container: Fedora floor, seed-on-boot home, manifest configs, optional personal addon.

If the repository does not exist yet:

```bash
gh repo create monotasker/nvim-sandbox --public --source=. --remote=origin --push
# then re-run gh repo edit …
```
