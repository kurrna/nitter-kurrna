# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, times, strformat, strutils, tables, hashes, os
import httpclient, json, base64
import flatty, supersnappy

import types, api

const
  redisNil = "\0\0"
  baseCacheTime = 60 * 60

var
  upstashUrl: string
  upstashToken: string
  rssCacheTime: int
  listCacheTime*: int

# Base64 encode/decode for binary data over REST API
proc encodeForRedis(data: string): string =
  encode(data)

proc decodeFromRedis(data: string): string =
  try:
    decode(data)
  except:
    data  # Return original if not base64

# Upstash REST API client
proc redisCmd(args: seq[string]): Future[JsonNode] {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()
  
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & upstashToken,
    "Content-Type": "application/json"
  })
  
  var cmdArray = newJArray()
  for arg in args:
    cmdArray.add(%arg)
  
  try:
    let resp = await client.post(upstashUrl, body = $cmdArray)
    let body = await resp.body
    result = parseJson(body)
  except:
    result = newJNull()

proc redisGet(key: string): Future[string] {.async.} =
  let resp = await redisCmd(@["GET", key])
  if resp.kind == JObject and resp.hasKey("result"):
    if resp["result"].kind == JString:
      result = resp["result"].getStr()
    elif resp["result"].kind == JNull:
      result = redisNil
    else:
      result = redisNil
  else:
    result = redisNil

proc redisSetEx(key: string; time: int; data: string) {.async.} =
  discard await redisCmd(@["SETEX", key, $time, data])

proc redisHSet(key, field, value: string) {.async.} =
  discard await redisCmd(@["HSET", key, field, value])

proc redisHGet(key, field: string): Future[string] {.async.} =
  let resp = await redisCmd(@["HGET", key, field])
  if resp.kind == JObject and resp.hasKey("result"):
    if resp["result"].kind == JString:
      result = resp["result"].getStr()
    elif resp["result"].kind == JNull:
      result = redisNil
    else:
      result = redisNil
  else:
    result = redisNil

proc redisExpire(key: string; seconds: int) {.async.} =
  discard await redisCmd(@["EXPIRE", key, $seconds])

proc redisPing(): Future[bool] {.async.} =
  let resp = await redisCmd(@["PING"])
  if resp.kind == JObject and resp.hasKey("result"):
    result = resp["result"].getStr() == "PONG"
  else:
    result = false

# flatty can't serialize DateTime, so we need to define this
proc toFlatty*(s: var string, x: DateTime) =
  s.toFlatty(x.toTime().toUnix())

proc fromFlatty*(s: string, i: var int, x: var DateTime) =
  var unix: int64
  s.fromFlatty(i, unix)
  x = fromUnix(unix).utc()

proc setCacheTimes*(cfg: Config) =
  rssCacheTime = cfg.rssCacheTime * 60
  listCacheTime = cfg.listCacheTime * 60

proc initRedisPool*(cfg: Config) {.async.} =
  # Get Upstash REST API credentials from environment
  upstashUrl = getEnv("UPSTASH_REDIS_REST_URL", "")
  upstashToken = getEnv("UPSTASH_REDIS_REST_TOKEN", "")
  
  if upstashUrl.len == 0 or upstashToken.len == 0:
    stdout.write "ERROR: UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN environment variables are required.\n"
    stdout.write "Get these values from your Upstash Redis dashboard.\n"
    stdout.flushFile
    quit(1)
  
  # Test connection with PING
  try:
    let ok = await redisPing()
    if not ok:
      raise newException(IOError, "Redis PING failed")
  except:
    stdout.write "Failed to connect to Upstash Redis.\nURL: " & upstashUrl & "\n"
    stdout.write "Error: " & getCurrentExceptionMsg() & "\n"
    stdout.flushFile
    quit(1)

template uidKey(name: string): string = "pid:" & $(hash(name) div 1_000_000)
template userKey(name: string): string = "p:" & name
template listKey(l: List): string = "l:" & l.id
template tweetKey(id: int64): string = "t:" & $id

proc get(query: string): Future[string] {.async.} =
  result = await redisGet(query)

proc setEx(key: string; time: int; data: string) {.async.} =
  await redisSetEx(key, time, data)

proc cacheUserId(username, id: string) {.async.} =
  if username.len == 0 or id.len == 0: return
  let name = toLower(username)
  await redisHSet(name.uidKey, name, id)

proc cache*(data: List) {.async.} =
  await setEx(data.listKey, listCacheTime, encodeForRedis(compress(toFlatty(data))))

proc cache*(data: PhotoRail; name: string) {.async.} =
  await setEx("pr2:" & toLower(name), baseCacheTime * 2, encodeForRedis(compress(toFlatty(data))))

proc cache*(data: User) {.async.} =
  if data.username.len == 0: return
  let name = toLower(data.username)
  await cacheUserId(name, data.id)
  await redisSetEx(name.userKey, baseCacheTime, encodeForRedis(compress(toFlatty(data))))

proc cache*(data: Tweet) {.async.} =
  if data.isNil or data.id == 0: return
  await redisSetEx(data.id.tweetKey, baseCacheTime, encodeForRedis(compress(toFlatty(data))))

proc cacheRss*(query: string; rss: Rss) {.async.} =
  let key = "rss:" & query
  await redisHSet(key, "min", rss.cursor)
  if rss.cursor != "suspended":
    await redisHSet(key, "rss", encodeForRedis(compress(rss.feed)))
  await redisExpire(key, rssCacheTime)

template deserialize(data, T) =
  try:
    result = fromFlatty(uncompress(decodeFromRedis(data)), T)
  except:
    echo "Decompression failed($#): '$#'" % [astToStr(T), data]

proc getUserId*(username: string): Future[string] {.async.} =
  let name = toLower(username)
  result = await redisHGet(name.uidKey, name)
  if result == redisNil:
    let user = await getGraphUser(username)
    if user.suspended:
      return "suspended"
    else:
      await all(cacheUserId(name, user.id), cache(user))
      return user.id

proc getCachedUser*(username: string; fetch=true): Future[User] {.async.} =
  let prof = await get("p:" & toLower(username))
  if prof != redisNil:
    prof.deserialize(User)
  elif fetch:
    result = await getGraphUser(username)
    await cache(result)

proc getCachedUsername*(userId: string): Future[string] {.async.} =
  let
    key = "i:" & userId
    username = await get(key)

  if username != redisNil:
    result = username
  else:
    let user = await getGraphUserById(userId)
    result = user.username
    await setEx(key, baseCacheTime, result)
    if result.len > 0 and user.id.len > 0:
      await all(cacheUserId(result, user.id), cache(user))

# proc getCachedTweet*(id: int64): Future[Tweet] {.async.} =
#   if id == 0: return
#   let tweet = await get(id.tweetKey)
#   if tweet != redisNil:
#     tweet.deserialize(Tweet)
#   else:
#     result = await getGraphTweetResult($id)
#     if not result.isNil:
#       await cache(result)

proc getCachedPhotoRail*(id: string): Future[PhotoRail] {.async.} =
  if id.len == 0: return
  let rail = await get("pr2:" & toLower(id))
  if rail != redisNil:
    rail.deserialize(PhotoRail)
  else:
    result = await getPhotoRail(id)
    await cache(result, id)

proc getCachedList*(username=""; slug=""; id=""): Future[List] {.async.} =
  let list = if id.len == 0: redisNil
             else: await get("l:" & id)

  if list != redisNil:
    list.deserialize(List)
  else:
    if id.len > 0:
      result = await getGraphList(id)
    else:
      result = await getGraphListBySlug(username, slug)
    await cache(result)

proc getCachedRss*(key: string): Future[Rss] {.async.} =
  let k = "rss:" & key
  result.cursor = await redisHGet(k, "min")
  if result.cursor.len > 2:
    if result.cursor != "suspended":
      let feed = await redisHGet(k, "rss")
      if feed.len > 0 and feed != redisNil:
        try: result.feed = uncompress(decodeFromRedis(feed))
        except: echo "Decompressing RSS failed: ", feed
  else:
    result.cursor.setLen 0
