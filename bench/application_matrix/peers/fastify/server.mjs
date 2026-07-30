import cluster from "node:cluster";
import Fastify from "fastify";

const small = {
  id: 42,
  name: "Ada",
  email: "ada@example.com",
  active: true,
};

const medium = {
  request_id: "req-0123456789abcdef",
  items: Array.from({ length: 64 }, (_, index) => ({
    id: index + 1,
    name: "item-abcdefghijklmnop",
    score: index + 1.5,
    active: true,
  })),
  tags: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"],
};

// The same document with an integer score. Odin's pinned encoder renders f64
// with sixteen decimals, so the float document is 960 bytes larger there and the
// two cannot be compared byte for byte. This one is byte-identical across every
// server in the matrix.
const mediumInt = {
  request_id: "req-0123456789abcdef",
  items: Array.from({ length: 64 }, (_, index) => ({
    id: index + 1,
    name: "item-abcdefghijklmnop",
    score: index + 1,
    active: true,
  })),
  tags: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"],
};

const smallSchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "name", "email", "active"],
  properties: {
    id: { type: "integer" },
    name: { type: "string" },
    email: { type: "string" },
    active: { type: "boolean" },
  },
};

const mediumItemSchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "name", "score", "active"],
  properties: {
    id: { type: "integer" },
    name: { type: "string" },
    score: { type: "number" },
    active: { type: "boolean" },
  },
};

const mediumSchema = {
  type: "object",
  additionalProperties: false,
  required: ["request_id", "items", "tags"],
  properties: {
    request_id: { type: "string" },
    items: { type: "array", items: mediumItemSchema },
    tags: { type: "array", items: { type: "string" } },
  },
};

const app = Fastify({
  logger: false,
  ajv: {
    customOptions: {
      coerceTypes: false,
      removeAdditional: false,
      useDefaults: false,
    },
  },
});

app.get("/health", async (_, reply) => {
  reply.type("text/plain; charset=utf-8");
  return "ok";
});
app.get("/json/small", async () => small);
app.get("/json/medium", async () => medium);
app.get("/json/medium/int", async () => mediumInt);
app.post("/json/echo", { schema: { body: smallSchema } }, async (request) => request.body);
app.post("/json/medium", { schema: { body: mediumSchema } }, async (request) => request.body);
app.post(
  "/json/medium/decode",
  { schema: { body: mediumSchema } },
  async (_, reply) => reply.code(204).send(),
);

const api = async (instance) => {
  instance.addHook("onRequest", async (request, reply) => {
    reply.header("X-Request-Id", String(request.id));
  });
  instance.addHook("preHandler", async () => {});
  instance.addHook("preHandler", async () => {});
  instance.addHook("preHandler", async (request) => {
    request.accountId = 7;
  });
  instance.get(
    "/users/:id",
    {
      schema: {
        params: {
          type: "object",
          required: ["id"],
          properties: { id: { type: "integer" } },
        },
        querystring: {
          type: "object",
          required: ["verbose"],
          properties: { verbose: { type: "integer" } },
        },
      },
    },
    async (request) => ({
      id: Number(request.params.id),
      account_id: request.accountId,
      verbose: Number(request.query.verbose) === 1,
    }),
  );
};

await app.register(api, { prefix: "/api" });

if (cluster.isPrimary) {
  const workers = Number(process.env.WORKERS ?? "1");
  for (let index = 0; index < workers; index += 1) {
    cluster.fork();
  }
} else {
  const port = Number(process.argv[2] ?? "8081");
  await app.listen({ host: "0.0.0.0", port });
}
