# Profil TelmiOS — R36S **V20** (legacy staging)

> **Depuis 0.5.0** : image unique `telmi-r36-<VERSION>.img` (défaut REV `v20`).  
> Voir [`profiles/README.md`](../README.md).

## Build legacy V20-only

```bash
bash Telmi-R36/scripts/build-telmi-bins.sh unified
bash Telmi-R36/scripts/assemble-telmi-unified.sh
```

Ou ancien pipeline : `assemble-telmi-v20.sh` (rootfs.tar + sudo).
