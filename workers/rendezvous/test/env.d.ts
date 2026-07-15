/// <reference types="@cloudflare/vitest-pool-workers/types" />

declare namespace Cloudflare {
  interface Env {
    ROOMS: DurableObjectNamespace<
      import("../src/index").RendezvousRoom
    >;
    SIGNALS: DurableObjectNamespace<
      import("../src/signaling").SignalingRoom
    >;
    SIGNAL_RATE_LIMIT: RateLimit;
    CONNECTION_RATE_LIMIT: RateLimit;
    ABUSE_METRICS: AnalyticsEngineDataset;
    ENVIRONMENT: "production" | "development" | "test";
  }
}
