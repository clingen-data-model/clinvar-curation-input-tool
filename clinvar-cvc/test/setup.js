import { vi } from 'vitest';

globalThis.chrome = {
  runtime: { sendMessage: vi.fn(), onMessage: { addListener: vi.fn() }, lastError: null },
  identity: {
    getProfileUserInfo: vi.fn((opts, cb) => cb({ email: 'tester@example.com' })),
    getAuthToken: vi.fn((opts, cb) => cb('fake-google-token'))
  },
  storage: { local: { get: vi.fn((k, cb) => cb({})), set: vi.fn((o, cb) => cb && cb()) } },
  tabs: { query: vi.fn(), sendMessage: vi.fn() }
};

globalThis.fetch = vi.fn();
