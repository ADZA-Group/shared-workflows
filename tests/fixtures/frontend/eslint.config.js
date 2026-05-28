import tseslint from "typescript-eslint";

// base = @typescript-eslint parser + plugin, NO rules enabled → parses TS, 0 violations.
export default [
  ...tseslint.configs.base,
];
