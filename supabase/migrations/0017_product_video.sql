-- Rex-Giddoty Hubs — a product can carry a short video
--
-- A clip of a bag being opened sells it in a way four photographs do not, so
-- the media on a product is no longer only photographs. It goes in the bucket
-- that is already there and already public: this is shop-window material, the
-- same as the photographs beside it.
--
-- No column is added. Whether a file is a video is read from its extension,
-- which is safe here because the uploader is what sets the name.

update storage.buckets
   set file_size_limit = 26214400,          -- 25MB, up from 10
       allowed_mime_types = array[
         'image/jpeg','image/png','image/webp','image/avif',
         'video/mp4','video/quicktime','video/webm','video/3gpp'
       ]
 where id = 'product-images';
