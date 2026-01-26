
const CACHE_NAME = 'video-stream-cache-v1';
const MAX_CACHE_SIZE = 500 * 1024 * 1024; // 500MB

// Track cache size
let currentCacheSize = 0;
const cacheMetadata = new Map(); // url -> { size, lastAccessed, complete }

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(clients.claim());
});

// Handle messages from Dart
self.addEventListener('message', async (event) => {
  if (!event.data) return;
  const { type, url, bytes, headers } = event.data;

  switch (type) {
    case 'UPDATE_CONFIG':
      await updateConfig(event.data);
      if (event.ports[0]) event.ports[0].postMessage({ success: true });
      break;

    case 'PRECACHE':
      await precacheVideo(url, bytes, headers);
      if (event.ports[0]) event.ports[0].postMessage({ success: true });
      break;

    case 'GET_STATUS':
      const status = cacheMetadata.get(url);
      if (event.ports[0]) {
        event.ports[0].postMessage({
          status: status ? (status.complete ? 'complete' : 'partial') : 'none'
        });
      }
      break;

    case 'CLEAR_CACHE':
      await clearCache();
      if (event.ports[0]) event.ports[0].postMessage({ success: true });
      break;

    case 'GET_SIZE':
      if (event.ports[0]) event.ports[0].postMessage({ size: currentCacheSize });
      break;
  }
});

let config = {
  keepCache: true,
  cacheTTL: 7 * 24 * 60 * 60 * 1000 // 7 days default
};

async function updateConfig(newConfig) {
  if (newConfig.keepCache !== undefined) config.keepCache = newConfig.keepCache;
  if (newConfig.cacheTTL !== undefined) config.cacheTTL = newConfig.cacheTTL;

  // Apply clean up if needed
  await performMaintenance();
}

async function performMaintenance() {
  const cache = await caches.open(CACHE_NAME);
  const now = Date.now();

  const entries = Array.from(cacheMetadata.entries());
  for (const [url, meta] of entries) {
    // TTL Check
    if (now - meta.lastAccessed > config.cacheTTL) {
      await cache.delete(url);
      cacheMetadata.delete(url);
      currentCacheSize -= meta.size;
      continue;
    }
  }

  // If keepCache is false, we might clear everything on session start/end,
  // but here we are in a service worker which persists. 
  // 'keepCache: false' usually means session-only cache.
  // We can simulate that by clearing on 'activate' if config says so, 
  // but config comes from Dart which might start later.
  // For now, let's treat 'keepCache: false' as aggressive cleanup? 
  // Or probably the user expects `clearCache` to be called on dispose.
  // We'll leave it to manual clear or TTL for now to be safe.
}

// Intercept video fetches
self.addEventListener('fetch', (event) => {
  const request = event.request;

  // Only handle video requests we're tracking or that look like video
  if (!shouldHandleRequest(request)) return;

  event.respondWith(handleVideoFetch(request));
});

function shouldHandleRequest(request) {
  // Handle video MIME types and known extensions
  const url = request.url.toLowerCase();
  return url.includes('.mp4') ||
    url.includes('.webm') ||
    url.includes('.m3u8') ||
    url.includes('.ts') ||
    request.destination === 'video';
}

async function handleVideoFetch(request) {
  const cache = await caches.open(CACHE_NAME);
  const url = request.url;

  // Update last accessed time
  if (cacheMetadata.has(url)) {
    cacheMetadata.get(url).lastAccessed = Date.now();
  }

  // Check for cached response
  const cachedResponse = await cache.match(request);

  if (cachedResponse) {
    const meta = cacheMetadata.get(url);

    // Only use cache if it is complete.
    // Partial cache (from precache) cannot be served as '200 OK' for a full video request
    // without confusing the browser, and stitching partial content is complex.
    // So we skip partial caches for playback to ensure stability.
    if (meta && meta.complete) {
      const rangeHeader = request.headers.get('Range');
      if (rangeHeader) {
        return handleRangeRequest(cachedResponse, rangeHeader);
      }
      return cachedResponse;
    }

    // If partial, we ignore it and let it fall through to network fetch
  }

  // Not cached, fetch from network
  try {
    const response = await fetch(request);

    // Cache successful responses if they are full responses (200)
    // Partial content (206) is harder to cache as a whole blob immediately without stitching
    if (response.ok && response.status === 200) {
      const clone = response.clone();
      // We don't await this to not block the response
      cacheResponse(url, clone);
    }

    return response;
  } catch (error) {
    // Network error, try partial cache?
    // For now simple fallback
    throw error;
  }
}

async function precacheVideo(url, bytes, headers = {}) {
  const cache = await caches.open(CACHE_NAME);

  // Check if already cached
  if (cacheMetadata.has(url)) return;

  try {
    // Fetch with Range header for partial precache
    // Note: 'bytes' param is how much to fetch
    const rangeHeader = bytes ? `bytes=0-${bytes - 1}` : undefined;
    const fetchHeaders = { ...headers };
    if (rangeHeader) {
      fetchHeaders['Range'] = rangeHeader;
    }

    const response = await fetch(url, { headers: fetchHeaders });

    if (response.ok || response.status === 206) {
      const isComplete = !rangeHeader && response.status === 200;
      await cacheResponse(url, response.clone(), isComplete);
    }
  } catch (error) {
    console.warn('Precache failed for:', url, error);
  }
}

async function cacheResponse(url, response, complete = true) {
  const cache = await caches.open(CACHE_NAME);
  const blob = await response.blob();
  const size = blob.size;

  // Evict if needed
  await ensureCacheSpace(size);

  // Store response
  // We need to store it as a full response to be useful for generic matching
  // But if it's partial, we might just store it as-is and handle it specially
  await cache.put(url, new Response(blob, {
    status: 200, // Store as 200 ok for internal usage, but we might need to serve 206
    headers: response.headers
  }));

  // Update metadata
  cacheMetadata.set(url, {
    size,
    lastAccessed: Date.now(),
    complete
  });
  currentCacheSize += size;
}

async function ensureCacheSpace(neededBytes) {
  if (currentCacheSize + neededBytes <= MAX_CACHE_SIZE) return;

  const cache = await caches.open(CACHE_NAME);

  // Sort by last accessed (LRU)
  const entries = Array.from(cacheMetadata.entries())
    .sort((a, b) => a[1].lastAccessed - b[1].lastAccessed);

  for (const [url, meta] of entries) {
    if (currentCacheSize + neededBytes <= MAX_CACHE_SIZE) break;

    await cache.delete(url);
    cacheMetadata.delete(url);
    currentCacheSize -= meta.size;
  }
}

async function clearCache() {
  await caches.delete(CACHE_NAME);
  cacheMetadata.clear();
  currentCacheSize = 0;
}

async function handleRangeRequest(cachedResponse, rangeHeader) {
  const blob = await cachedResponse.blob();
  const totalSize = blob.size;

  // Parse range header: "bytes=0-999"
  const bytesPrefix = "bytes=";
  if (!rangeHeader.startsWith(bytesPrefix)) return cachedResponse;

  const ranges = rangeHeader.substring(bytesPrefix.length).split('-');
  const startStr = ranges[0];
  const endStr = ranges[1];

  const start = parseInt(startStr, 10);
  const end = endStr ? parseInt(endStr, 10) : totalSize - 1;

  if (isNaN(start)) return cachedResponse;

  const actualEnd = Math.min(end, totalSize - 1);
  const chunk = blob.slice(start, actualEnd + 1);

  return new Response(chunk, {
    status: 206,
    statusText: 'Partial Content',
    headers: {
      'Content-Range': `bytes ${start}-${actualEnd}/${totalSize}`,
      'Content-Length': chunk.size,
      'Content-Type': cachedResponse.headers.get('Content-Type') || 'video/mp4'
    }
  });
}
