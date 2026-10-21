# pnpm on shared runners

All runners on a host share one pnpm store on the `runner-caches` volume, at `/caches/pnpm-store`.
pnpm locks the store for concurrent use, so a warm install takes seconds.

## Settings (in `compose/runner.yml`)

- **Both prefixes.** pnpm 10 reads `npm_config_store_dir`; pnpm 11+ ignores `npm_config_*` for
  non-auth settings and reads only `pnpm_config_*`. Both pairs are set, and the stores sit side by
  side (`v10/`, `v11/`).
- **`package_import_method: copy`.** The store is a volume and the workspace is the container's
  overlay filesystem, so hardlinks can't cross between them. pnpm's default `auto` probes clone,
  then hardlink, then copy, and the probing intermittently lost a package's staging directory
  mid-import (`ERR_PNPM_ENOENT ... copyfile`) with the store file present before and after.
  `copy` avoids the probing.

## Don't use `pnpm/action-setup` with pnpm 11+ against a shared store

pnpm 11+ installs *itself* into the store (`v11/links/@pnpm/...`), and its native binary is a
hardlink of a store file. `pnpm/action-setup` bootstraps one pnpm and then "switches" to the
version in `packageManager` *through the store*. The second such switch on a shared store
replaced pnpm's native binary with a 3.5 KB placeholder script. From then on, every job on every
runner died in "Setup pnpm" (`ERR_PNPM_BROKEN_PNPM_INSTALL`), and nothing repaired it.

Install pnpm directly instead:

```yaml
- name: Install pnpm
  run: npm i -g "pnpm@$(node -p "require('./package.json').packageManager.split('@')[1].split('+')[0]")"
```

The watchdog (`maintenance/host-maintenance.sh`) detects a placeholder-sized pnpm binary in the
store and wipes `pnpm-store/v11`, which refills (~1 GB) on the next job.

## Don't use `setup-node`'s cache

`actions/setup-node` with `cache: pnpm` uploads the whole store to GitHub's cache service after
every job and downloads it before the next. On self-hosted runners that's pure cost: the local
store is already the cache, and the uploads have stalled jobs for an hour on a slow uplink. Make
it conditional:

```yaml
- uses: actions/setup-node@v4
  with:
    node-version-file: .nvmrc
    cache: ${{ !vars.CI_RUNNER && 'pnpm' || '' }}     # '' && x is falsy, so test the negation
```
