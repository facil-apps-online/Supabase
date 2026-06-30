import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import puppeteer from 'https://deno.land/x/puppeteer@16.2.0/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { htmlContent } = await req.json();
    if (!htmlContent) {
      throw new Error('htmlContent is required in the request body.');
    }

    // Get the API key from Supabase secrets
    const browserlessApiKey = Deno.env.get('BROWSERLESS_API_KEY');
    if (!browserlessApiKey) {
      throw new Error('BROWSERLESS_API_KEY is not set in Supabase secrets.');
    }

    const browserWSEndpoint = `wss://chrome.browserless.io?token=${browserlessApiKey}`;

    // --- WebSocket Connection Test ---
    try {
      console.log("Attempting to establish a test WebSocket connection...");
      const testSocket = new WebSocket(browserWSEndpoint);
      await new Promise((resolve, reject) => {
        testSocket.onopen = () => {
          console.log("Test WebSocket connection opened successfully!");
          testSocket.close();
          resolve(null);
        };
        testSocket.onerror = (event) => {
          // The 'error' event in Deno's WebSocket is not very descriptive,
          // the real error is often in the close event or the initial exception.
          console.error("Test WebSocket 'error' event:", event);
          reject(new Error("WebSocket errored. See logs for details."));
        };
        testSocket.onclose = (event) => {
          console.log("Test WebSocket closed.", event.code, event.reason);
        };
      });
      console.log("Test WebSocket connection succeeded.");
    } catch (e) {
      console.error("Failed to establish test WebSocket connection:", e);
      // Re-throw to ensure the function fails clearly if the test fails.
      throw new Error(`Test WebSocket connection failed: ${e.message}`);
    }
    // --- End WebSocket Connection Test ---

    const browser = await puppeteer.connect({ browserWSEndpoint });
    const page = await browser.newPage();
    
    await page.setContent(htmlContent, { waitUntil: 'networkidle0' });

    const pdfBuffer = await page.pdf({
      format: 'Letter',
      printBackground: true,
      margin: {
        top: '40pt',
        right: '40pt',
        bottom: '40pt',
        left: '40pt',
      },
    });

    await browser.close();

    return new Response(pdfBuffer, {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/pdf',
      },
      status: 200,
    });

  } catch (error) {
    console.error('Error generating PDF with Browserless:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
