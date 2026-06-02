export default {
  async fetch(_request: Request): Promise<Response> {
    return new Response("hello world\n", {
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
} satisfies ExportedHandler;
