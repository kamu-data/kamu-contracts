# Developer Guide <!-- omit in toc -->

- [Building Locally](#building-locally)
- [Deploy Locally](#deploy-locally)

## Building Locally

Prerequisites:

- (optional) [`nvm`](https://github.com/nvm-sh/nvm) for managing `node` versions
- [`node`](https://nodejs.org/en) (see version in `.nvmrc`)
- [`foundry`](https://github.com/foundry-rs/foundry)

If you use `nvm` - switch to the right version of `node`:

```sh
nvm use
```

Initialize the dependencies:

```sh
npm ci
```

Run tests:

```sh
forge test
```

Get a test coverage report:

```sh
forge coverage
```

Get a gas report:

```sh
forge test --gas-report
```

## Deploy Locally

Start Anvil:

```sh
anvil
```

Check `.env.local` for the set of configuration used.

Run deploy script:

```sh
npm run deploy:local
```

See also:

```sh
# Send transaction to authorize local provider
npm run send:add-provider:local

# Trigger oracle request transaction from the test consumer contract
npm run send:oracle:local
```
