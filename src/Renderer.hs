{-# LANGUAGE OverloadedStrings #-}

module Renderer
    where

import Prelude hiding (any, mapM_)
import Control.Monad hiding (mapM_)
import Control.Arrow ((***))
import Data.Foldable hiding (elem)
import Data.Maybe
import Data.Word8
import Data.List
import Data.Cross
import Foreign.C.Types
import SDL.Vect
import SDL (($=))
import qualified SDL
import Matrix as Matrix
import SDL_Aux
import Triangle
import Model
import Light
import Camera
import Control.Lens
import Geometry
--fromMatV4toV3 (viewport_mat * projection_mat *
draw_loop :: Screen -> Model -> Light -> Camera -> IO()
draw_loop screen model light camera = do
    let zbuffer = replicate ((width_i screen)*(height_i screen)) (-100000)
        t_faces = faces model
        t_verts = verts model
        t_norms = norms model
        t_uvs = uvs model
        projection_mat = cam_projection_matrix camera
        viewport_mat = viewport_matrix ((fromIntegral $ width_i screen)/8.0) ((fromIntegral $ height_i screen)/8.0) ((fromIntegral $ width_i screen)*0.75) ((fromIntegral $ height_i screen)*0.75)
    
    --------    Get [(screen coordinates of face vertex, world coordinates of face vertex)] of each face
    screen_world_coords <-  mapM (\ind -> do 
                                   
                                    let face = model_face model ind 
                                        (w_v0, w_v1, w_v2) = mapTuple3 (\i -> model_vert model (fromIntegral $ (face !! i))) (0,1,2)
                           
                                    let screen_coord (V3 a b c) = (( fromMatV4toV3 ( viewport_mat * projection_mat * (fromV3toMatV4 (V3 a b c)) )) :: (V3 Double))
                                        (s_v0, s_v1, s_v2) = mapTuple3 (\v -> screen_coord v)  (w_v0, w_v1, w_v2)
                                    -- print ((s_v0, s_v1, s_v2),  (w_v0, w_v1, w_v2))

                                    return $ (((s_v0, s_v1, s_v2),  (w_v0, w_v1, w_v2)) :: ((V3 Double, V3 Double, V3 Double), (V3 Double, V3 Double, V3 Double)))) ([0 .. (nfaces model) - 1] :: [Int])

    let screen_coords = map (\(x,y) -> x) screen_world_coords   -- :: [(V3 Double, V3 Double, V3 Double)]
        world_coords  = map (\(x,y) -> y) screen_world_coords   -- :: [(V3 Double, V3 Double, V3 Double)]
        process_triangles idx coords = case coords of (x:xs) -> (\(screen_v, world_v) -> do
                                                                           
                                                                            let (world_0, world_1, world_2) = world_v
                                                                                norm = norm_V3 $ or_V3  (world_2 - world_0) (world_1 - world_2)
                                                                                light_intensity = norm * (direction light)
                                                                            when (light_intensity > 0) (do 
                                                                                -- print idx                        
                                                                                let uv = mapTuple3 (model_uv model idx) ((0, 1, 2) :: (Int, Int, Int))
                                                                                draw_triangle screen screen_v uv zbuffer 
                                                                               
                                                                                return ())
                                                                            process_triangles (idx + 1) xs) x
                                                      [] -> return ()

    process_triangles 0 screen_world_coords
    return ()

-- #             Screen ->   Projected 2D Triangle Vertices   ->   UV Coordinates Z-Buffer  -> Updated Z-Buffer                     
draw_triangle :: Screen ->  (V3 Double, V3 Double, V3 Double) ->  (V2 Double, V2 Double, V2 Double) -> [Double] -> IO [Double]
draw_triangle screen screen_vertices uv_vertices zbuffer  = do
    let ((V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z), (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v)) = order_vertices screen_vertices uv_vertices 0
        ((v0, v1, v2), (uv0, uv1, uv2)) = ((V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z), (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v))
        triangle_height = v2y - v0y
    v_list <- mapM (\i -> do
            let h = fromIntegral i

                second_half = (h > (v1y - v0y)) || ((floor v1y) == (floor v0y)) 
                segment_height = if second_half then v2y - v1y else v1y - v0y
                alpha = h / ( triangle_height)
                beta = if second_half then (h - (v1y - v0y))/segment_height else h / segment_height
               
                vA = v0 + (mul_V3_Num (v2 - v0) ( alpha))  
                vB = if second_half then v1 + (mul_V3_Num (v2 - v1) beta) else v0 + (mul_V3_Num (v1 - v0) beta)
                uvA = uv0 + (mul_V2_Num (uv2 - uv0) ( alpha))   
                uvB = if second_half then uv1 + (mul_V2_Num (uv2 - uv1) beta) else uv0 + (mul_V2_Num (uv1 - uv0) beta)
              
            return $ ((order_min_x (vA, vB) (uvA, uvB)  ), i)  ) ([0 .. (fromIntegral $ floor triangle_height)] :: [Int])

    zbuffer' <- draw_help v_list zbuffer screen
    return zbuffer'


draw_help :: [(((V3 Double, V3 Double), (V2 Double, V2 Double)), Int)] -> [Double] -> Screen -> IO [Double]
draw_help v_list zbuffer screen = case v_list of (x:xs) ->  do
                                                        let ((V3 vAx vAy vAz, V3 vBx vBy vBz), (V2 vAu vAv, V2 vBu vBv)) = fst x
                                                        zbuffer' <- draw_helper v_list (vAx, vBx) vAx screen zbuffer 
                                                      
                                                        draw_help xs zbuffer' screen
                                                 []     -> return zbuffer

draw_helper :: [(((V3 Double, V3 Double), (V2 Double, V2 Double)), Int)] -> (Double, Double) -> Double -> Screen -> [Double] -> IO [Double]
draw_helper v_list (start, end) index screen zbuffer =
                                    if index > end
                                        then return zbuffer
                                        else case v_list of (v:vs) ->      do

                                                                        let ((V3 vAx vAy vAz, V3 vBx vBy vBz), (V2 vAu vAv, V2 vBu vBv)) = fst v
                                                                            ((vA', vB'), (uvA', uvB')) =  fst v

                                      
                                                                        let phi = if (floor vBx) == (floor vAx) then (1.0 :: Double) else (index - vAx) / ( vBx - vAx)
                                                                            (V3 px py pz) = vA' + (mul_V3_Num (vB' - vA') ( phi))
                                                                            (V2 pu pv) = uvA' + (mul_V2_Num (uvB' - uvA') ( phi))
                                                                            idx = fromIntegral $ floor $ px + py * (fromIntegral $ width_i screen)
                                                        
                                                                        if (zbuffer !! (idx)) < ( pz)
                                                                            then ( do
                                                                                print(idx)
                                                                                let zbuffer' = replaceAt ( pz) idx zbuffer
                                                                                sdl_put_pixel screen (V2 (fromIntegral $ floor px) ( fromIntegral $ floor py)) (get_color Blue)
                                                                                draw_helper vs (start,end) (index + 1) screen zbuffer')
                                                                            else ( do
                                                                                print(idx)
                                                                                draw_helper vs (start,end) (index + 1) screen zbuffer)
                                                            [] -> return zbuffer
                                    
                    
                    
                    
                    
                    
                    
                    
                    
                
                --( ([(floor vAx) .. (floor vBx)]) :: [Int]  )
--     bound_min = V2 ((fromIntegral $ toInteger $ width screen) - (1.0 :: Double) ) (((fromIntegral $ toInteger $ height screen) - 1.0 ))
--     bound_max = V2 (0 :: Double) (0 :: Double)
--     clamped = bound_min

--     (V4 v0x v0y v0z v0w, V4 v1x v1y v1z v1w, V4 v2x v2y v2z v2w) = projected_vertices
--     projected_vert_2D = (V2 v0x v0y, V2 v1x v1y, V2 v2x v2y)

--     bbox_min_x =  max 0 (foldr (\(V2 x y) (b) -> (min x  b) ) ((\(V2 xb yb) -> min xb yb) bound_min)  (concat  $ map (^..each) [projected_vert_2D])    )
--     bbox_min_y =  max 0 (foldr (\(V2 x y) (b) -> (min y  b) ) ((\(V2 xb yb) -> min xb yb) bound_min) (concat  $ map (^..each) [projected_vert_2D]) )
--     bbox_max_x =  min ((\(V2 xb yb) -> xb) (fromIntegral $ toInteger $ width screen)) (foldr (\(V2 x y) (b) -> (max y b) ) ((\(V2 xb yb) -> max xb yb) bound_max) (concat  $ map (^..each) [projected_vert_2D]) )
--     bbox_max_y =  min ((\(V2 xb yb) -> yb) (fromIntegral $ toInteger $ height screen)) (foldr (\(V2 x y) (b) -> (max y b) ) ((\(V2 xb yb) -> max xb yb) bound_max) (concat  $ map (^..each) [projected_vert_2D]) )
    
--     fillpoints =   [ (px, py, zdepth, fromIntegral zbuffer_index)
--                                 | px <- [bbox_min_x .. bbox_max_x], py <- [bbox_min_y .. bbox_max_y], 
--                                             let (V3 barx bary barz) = barycentric (V2 v0x v0y, V2 v1x v1y, V2 v2x v2y) (V2 (realToFrac  px) (realToFrac py)),
--                                             let zdepth = sum $ zipWith (*)  [v0z, v1z, v2z] [barx, bary, barz],
--                                             let zbuffer_index = (floor px + (floor py) * (fromIntegral $ toInteger $ width screen)),
--                                             barx >= 0 && bary >=0 && barz >=0 && (zbuffer !! zbuffer_index) < zdepth]
-- print (fillpoints)
-- sequence $ map (\(px,py,zdepth,zbuffer_index) -> 
--                     sdl_put_pixel screen ( V2 (fromInteger px) (fromInteger py) ) (color triangle)) 
--                         (map (\(px', py', zdepth', zind') -> (floor px', floor py',floor zdepth',floor zind'))  fillpoints)

-- let f (zbuffer') fillpoints' = case fillpoints' of
--                                 (x:xs) -> let zbuffer'' = (\(px, py, zdepth, zbuffer_index) -> replaceAt zdepth (floor zbuffer_index) (zbuffer') ) x
--                                           in f (zbuffer'' :: [Double]) xs
--                                 []      -> (zbuffer'  :: [Double])
--     zbuffer' = f zbuffer fillpoints

--'



order_min_x :: (V3 Double, V3 Double) -> (V2 Double, V2 Double) -> ((V3 Double, V3 Double), (V2 Double, V2 Double))
order_min_x (V3 vAx vAy vAz, V3 vBx vBy vBz) (V2 vAu vAv, V2 vBu vBv)
    | (vAx > vBx) = ((V3 vBx vBy vBz, V3 vAx vAy vAz), (V2 vBu vBv, V2 vAu vAv))
    | otherwise   = ((V3 vAx vAy vAz, V3 vBx vBy vBz), (V2 vAu vAv, V2 vBu vBv))

order_vertices :: (V3 Double, V3 Double, V3 Double) -> (V2 Double, V2 Double, V2 Double) -> Int ->  ((V3 Double, V3 Double, V3 Double), (V2 Double, V2 Double, V2 Double))
order_vertices (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) stage
    | stage == 0 = if (v0y > v1y)   then order_vertices (V3 v1x v1y v1z, V3 v0x v0y v0z, V3 v2x v2y v2z)  (V2 v1u v1v, V2 v0u v0v, V2 v2u v2v) 1 
                                    else order_vertices (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) 1
    | stage == 1 = if (v0y > v2y)   then order_vertices (V3 v2x v2y v2z, V3 v1x v1y v1z, V3 v0x v0y v0z)  (V2 v2u v2v, V2 v1u v1v, V2 v0u v0v) 2
                                    else order_vertices (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) 2
    | stage == 2 = if (v1y > v2y)   then order_vertices (V3 v0x v0y v0z, V3 v2x v2y v2z, V3 v1x v1y v1z)  (V2 v0u v0v, V2 v2u v2v, V2 v1u v1v) 3
                                    else order_vertices (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) 3
    | otherwise = ((V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z), (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v))

order_min_x_i :: (V3 Int, V3 Int) -> (V2 Int, V2 Int) -> ((V3 Int, V3 Int), (V2 Int, V2 Int))
order_min_x_i (V3 vAx vAy vAz, V3 vBx vBy vBz) (V2 vAu vAv, V2 vBu vBv)
    | (vAx > vBx) = ((V3 vBx vBy vBz, V3 vAx vAy vAz), (V2 vBu vBv, V2 vAu vAv))
    | otherwise   = ((V3 vAx vAy vAz, V3 vBx vBy vBz), (V2 vAu vAv, V2 vBu vBv))

order_vertices_i :: (V3 Int, V3 Int, V3 Int) -> (V2 Int, V2 Int, V2 Int) -> Int -> ((V3 Int, V3 Int, V3 Int), (V2 Int, V2 Int, V2 Int))
order_vertices_i (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) stage
    | stage == 0 = if (v0y > v1y)   then order_vertices_i (V3 v1x v1y v1z, V3 v0x v0y v0z, V3 v2x v2y v2z)  (V2 v1u v1v, V2 v0u v0v, V2 v2u v2v) 1 
                                    else order_vertices_i (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) 1
    | stage == 1 = if (v0y > v2y)   then order_vertices_i (V3 v2x v2y v2z, V3 v1x v1y v1z, V3 v0x v0y v0z)  (V2 v2u v2v, V2 v1u v1v, V2 v0u v0v) 2
                                    else order_vertices_i (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) 2
    | stage == 2 = if (v1y > v2y)   then order_vertices_i (V3 v0x v0y v0z, V3 v2x v2y v2z, V3 v1x v1y v1z)  (V2 v0u v0v, V2 v2u v2v, V2 v1u v1v) 3
                                    else order_vertices_i (V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z)  (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v) 3
    | otherwise = ((V3 v0x v0y v0z, V3 v1x v1y v1z, V3 v2x v2y v2z), (V2 v0u v0v, V2 v1u v1v, V2 v2u v2v))

-- cam_mat = cam_projection_matrix camera
-- viewport_mat = viewport_matrix (fromIntegral $ toInteger $ width screen)/8.0 (fromIntegral $ toInteger $ height screen)/8.0 (fromIntegral $ toInteger $ width screen)*0.75 (fromIntegral $ toInteger $ height screen)*0.75


-- f next_zbuff next_triangles = case next_triangles of (x:xs) -> do 
--                                                             let (va, vb, vc) = points x
--                                                             -- print $ toLists $ cam_matrix * (toMatV4 va) ------- Fix this
--                                                             let v_a = (fromMatV4 $ cam_matrix * (toMatV4 va))
--                                                                 v_b = (fromMatV4 $ cam_matrix * (toMatV4 vb))
--                                                                 v_c = (fromMatV4 $ cam_matrix * (toMatV4 vc))
--                                                             next_zbuff' <- draw_triangle screen (v_a, v_b, v_c) next_zbuff x
--                                                             f next_zbuff' xs 
--                                                      [] -> return ()