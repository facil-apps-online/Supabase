import { serve } from "https://deno.land/std@0.224.0/http/mod.ts";
import { hash, verify } from "https://deno.land/x/scrypt@v1.0.0/mod.ts";

serve(async (req) => {
  const url = new URL(req.url);

  if (req.method === "POST") {
    try {
      if (url.pathname.endsWith("/hash")) {
        const { password } = await req.json();
        if (!password) {
          return new Response(JSON.stringify({ error: "Password is required" }), {
            headers: { "Content-Type": "application/json" },
            status: 400,
          });
        }
        const hashedPassword = await hash(password);
        return new Response(JSON.stringify({ hash: hashedPassword }), {
          headers: { "Content-Type": "application/json" },
          status: 200,
        });
      } else if (url.pathname.endsWith("/verify")) {
        const { password, hash: receivedHash } = await req.json(); // Rename hash to avoid conflict
        if (!password || !receivedHash) {
          return new Response(JSON.stringify({ error: "Password and hash are required" }), {
            headers: { "Content-Type": "application/json" },
            status: 400,
          });
        }
        const isMatch = await verify(password, receivedHash);
        return new Response(JSON.stringify({ match: isMatch }), {
          headers: { "Content-Type": "application/json" },
          status: 200,
        });
      } else {
        return new Response("Not Found", { status: 404 });
      }
    } catch (error) {
      return new Response(JSON.stringify({ error: error.message }), {
        headers: { "Content-Type": "application/json" },
        status: 400,
      });
    }
  }

  return new Response("Method Not Allowed", { status: 405 });
});