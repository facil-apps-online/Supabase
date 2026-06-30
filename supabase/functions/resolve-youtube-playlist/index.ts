import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

// --- Helper Functions ---

const jsonResponse = (data: unknown, status = 200, headers?: HeadersInit) => {
  const defaultHeaders = { 'Content-Type': 'application/json', ...headers };
  return new Response(JSON.stringify(data), { status, headers: defaultHeaders });
};

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Parses ISO 8601 duration format (e.g., PT1M35S) into seconds
function parseDuration(isoDuration: string): number {
  const regex = /PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;
  const matches = isoDuration.match(regex);
  if (!matches) return 0;
  const hours = parseInt(matches[1] || '0', 10);
  const minutes = parseInt(matches[2] || '0', 10);
  const seconds = parseInt(matches[3] || '0', 10);
  return (hours * 3600) + (minutes * 60) + seconds;
}


// --- Main Handler ---

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { videoUrl } = await req.json(); // Renamed from playlistUrl for clarity
    if (!videoUrl) {
      return jsonResponse({ error: 'videoUrl is required' }, 400, corsHeaders);
    }

    const url = new URL(videoUrl);
    const playlistId = url.searchParams.get('list');
    const videoId = url.searchParams.get('v');

    const apiKey = Deno.env.get('YOUTUBE_API_KEY');
    if (!apiKey) {
      console.error('YOUTUBE_API_KEY is not set');
      return jsonResponse({ error: 'Server configuration error' }, 500, corsHeaders);
    }

    let videoIds: string[] = [];

    // --- Logic for Playlists ---
    if (playlistId) {
      const playlistApiUrl = `https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&playlistId=${playlistId}&key=${apiKey}&maxResults=50`;
      const playlistResponse = await fetch(playlistApiUrl);
      if (!playlistResponse.ok) throw new Error('Failed to fetch playlist items from YouTube');
      const playlistData = await playlistResponse.json();
      videoIds = playlistData.items.map((item: any) => item.snippet.resourceId.videoId);
    
    // --- Logic for Single Video ---
    } else if (videoId) {
      videoIds = [videoId];
    
    } else {
      return jsonResponse({ error: 'URL must contain a valid playlist ID or video ID' }, 400, corsHeaders);
    }

    if (videoIds.length === 0) {
      return jsonResponse({ videos: [] }, 200, corsHeaders);
    }

    // --- Fetch details for all collected video IDs ---
    const videoIdsString = videoIds.join(',');
    const videosApiUrl = `https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=${videoIdsString}&key=${apiKey}`;
    
    const videosResponse = await fetch(videosApiUrl);
    if (!videosResponse.ok) throw new Error('Failed to fetch video details from YouTube');
    const videosData = await videosResponse.json();

    const videoDetails = videosData.items.map((item: any) => ({
      videoUrl: `https://www.youtube.com/watch?v=${item.id}`,
      title: item.snippet.title,
      durationSeconds: parseDuration(item.contentDetails.duration),
    }));

    return jsonResponse({ videos: videoDetails }, 200, corsHeaders);

  } catch (error) {
    console.error('Internal Server Error:', error);
    return jsonResponse({ error: 'An unexpected error occurred', details: error.message }, 500, corsHeaders);
  }
});