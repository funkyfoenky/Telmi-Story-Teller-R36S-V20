#!/usr/bin/env bash
# Alias : assemble profil V30 (appelle la variante rootless).
# Pour un assemble avec sudo/losetup, utiliser la meme logique via rootless
# (recommandee) — le resultat image est identique.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assemble-telmi-v30-rootless.sh" "$@"
