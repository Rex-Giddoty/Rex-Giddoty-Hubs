-- Rex-Giddoty Hubs — short videos in support chat
--
-- "Is this what arrived?" is often answered better by four seconds of video
-- than by three photographs. Kept short deliberately: the ceiling here is the
-- only thing the server can actually enforce, and the browser refuses anything
-- longer than a minute before it starts uploading.

update storage.buckets
   set file_size_limit = 26214400,          -- 25MB, up from 10
       allowed_mime_types = array[
         'image/jpeg','image/png','image/webp','image/avif','image/gif','image/heic',
         'application/pdf',
         'video/mp4','video/quicktime','video/webm','video/3gpp'
       ]
 where id = 'support-files';
