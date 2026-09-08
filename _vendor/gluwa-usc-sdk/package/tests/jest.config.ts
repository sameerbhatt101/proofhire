import type { Config } from '@jest/types';
import path from 'path';

const rootDir = path.resolve();

const config: Config.InitialOptions = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testTimeout: 30_000,
  globalSetup: './tests/globalSetup.ts',
  collectCoverage: true,
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'html', 'lcov', 'json'],
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts', '!src/**/*.test.ts'],
  coveragePathIgnorePatterns: ['/node_modules/', '/tests/', '/dist/'],
  rootDir: rootDir,
  roots: ['<rootDir>/src', '<rootDir>/tests'],
};

export default config;
