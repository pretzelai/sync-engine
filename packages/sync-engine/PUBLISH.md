# Build & Publish Instructions

## Prerequisites

- pnpm installed (`npm install -g pnpm`)
- npm logged in (`npm login`)

## Steps

```bash
# 1. Navigate to this directory
cd ~/work/paymentsdb-sync-engine/packages/sync-engine

# 2. Install dependencies
pnpm install --ignore-workspace

# 3. Build
pnpm run build

# 4. Bump version (patch/minor/major)
npm version patch

# 5. Publish
npm publish --access public

# 6. Update paymentsdb to use new version
cd ~/work/paymentsdb
npm update @paymentsdb/sync-engine
```

## Notes

- Use `--ignore-workspace` to avoid monorepo dependency issues
- `--access public` is required for scoped packages (@paymentsdb/...)
- Migrations run automatically on customer databases when sync engine deploys
