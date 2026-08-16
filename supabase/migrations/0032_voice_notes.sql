-- Voice notes in support.
--
-- A voice note is an attachment like any other — the bucket, the path check
-- against the thread that owns it, and the signed URL on the way back out are
-- all already there. The only thing stopping one was that the bucket refuses a
-- type it has not been told about.
--
-- Both families are allowed because browsers do not agree on what they record:
-- Chrome produces WebM/Opus, Safari produces MP4/AAC. Whichever end recorded
-- it, the other end has to be able to receive it.

update storage.buckets
   set allowed_mime_types = allowed_mime_types || array[
         'audio/webm',
         'audio/ogg',
         'audio/mp4',
         'audio/mpeg',
         'audio/aac',
         'audio/wav'
       ]
 where id = 'support-files'
   and not (allowed_mime_types @> array['audio/webm']);
