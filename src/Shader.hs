{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

        -- |‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾| -- 
        -- |                                                                        | -- 
        -- |                     	     SHADER FUNCTIONS                           | -- 
        -- |                                                                        | -- 
        -- |                                                                        | -- 
        --  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾  -- 

module Shader
    where

import Prelude hiding (any, mapM_)
import SDL (($=))
import qualified SDL
import Debug.Trace as Trace
import Data.Cross
import Data.Word8
import qualified Data.Vector as V
import Data.Vec as Vec hiding (foldr)
import Camera
import Model
import SDLx
import Control.Monad.Par
import Light
import Geometry
import Types
import Util
import System.CPUTime



vertex_shade :: Shader -> Rasteriser -> Face  -> (Mat34 Double, Shader)
vertex_shade (DirectionalLightShader modelview viewport projection mvp_mat transformM varying_tri) ras face = 
    let 
        Face vertices uvs vertnorms = face
        model = getModel ras
 
        screen_vert = multmm (Vec.map cartesianToHomogeneous vertices) (Vec.transpose mvp_mat )

        new_varying_tri = Vec.transpose $ Vec.map homogeneousToCartesian screen_vert

    in (screen_vert, DirectionalLightShader modelview viewport projection mvp_mat transformM new_varying_tri)
    
vertex_shade (AmbientLightShader modelview viewport projection mvp_mat varying_tri ) ras face = 
    let 
        Face vertices uvs vertnorms = face
        model = getModel ras
   
        screen_vert = multmm (Vec.map cartesianToHomogeneous vertices) (Vec.transpose mvp_mat )

        new_varying_tri = Vec.transpose $ (Vec.map homogeneousToCartesian) screen_vert

    in (screen_vert, AmbientLightShader modelview viewport projection mvp_mat new_varying_tri ) 

vertex_shade (CameraShader mview vport proj mvp_mat uni_M uni_MIT uni_Mshadow vary_uv vary_tri) 
    ras face = 
        let model = getModel ras
            Face vertices uvs vertnorms = face
            
            new_vary_uv  =  uvs :: Mat23 Double

            screen_vert = multmm (Vec.map cartesianToHomogeneous vertices) (Vec.transpose mvp_mat )
            new_vary_tri = Vec.transpose $  (Vec.map homogeneousToCartesian) screen_vert


        in (screen_vert, CameraShader mview vport proj mvp_mat uni_M uni_MIT uni_Mshadow new_vary_uv new_vary_tri) 



fragment_shade :: Shader -> Rasteriser -> Vec3 Double -> Int -> Par (Rasteriser, Shader)
fragment_shade shader ras bary_coords index = case shader of

    (DirectionalLightShader { getCurrentTri = current_tri, getTransformM = transM , ..}) -> 
        do
            let 
                (px, py, pz) = (fromVec3 $ multmv current_tri bary_coords)  :: (Double, Double, Double)
            
                color = (mult_rgba_d (toVec4 255 255 255 255)  pz)
                updatedbuffer = replaceAt  (pz, color) index (getDepthBuffer ras)
                updatedras = ras {getDepthBuffer = updatedbuffer}


            return (updatedras , shader) 

    (CameraShader { getCurrentTri = vary_tri, getCurrentUV = vary_uv, getUniformM = uni_M, getUniformMIT = uni_MIT, getUniformMShadow = uni_Mshadow ,.. }) -> 
       do  
            let p                               = multmv vary_tri bary_coords
                (sb_px, sb_py, sb_pz)           = fromVec3 $ homogeneousToCartesian (multmv uni_Mshadow (cartesianToHomogeneous $ p))
                shadow_idx                      = (floor sb_px) + (floor sb_py) * screenWidth_i
            if shadow_idx > (screenWidth_i * screenHeight_i) 
            then return (ras, shader) 
            else do 
                let Rasteriser {getModel = model, getLight = light, getDepthBuffer = depthBuffer, getZBuffer = zBuffer, ..} = ras
                    currentBufferValue              = fst (depthBuffer V.! shadow_idx)
                    light_intensity                 = (intensity light)
                    inverse_shadow                  = if currentBufferValue > sb_pz then sb_pz else (sb_pz) * light_intensity

                    uv          = multmv (vary_uv :: Mat23 Double) (bary_coords :: Vec3 Double) 

                    norm        = Vec.normalize $ homogeneousToCartesian $ multmv uni_MIT (cartesianToHomogeneous (model_normal model uv))  :: Vec3 Double ----
                    light_dir   = Vec.normalize $ homogeneousToCartesian $ multmv uni_M (cartesianToHomogeneous (direction light))   :: Vec3 Double
                    spec        = (max ((dot norm light_dir) * 4.0) (0.0)) * (Vec.norm $ model_specular model uv) * 2.0 * light_intensity
                    
                    diffuse     = model_diffuse model uv :: Vec4 Word8

                    color       = add_rgba_d (mult_rgba_d (diffuse) (inverse_shadow * 1.2  + spec * 3.0 ) ) (5)
                    pz          = Vec.getElem 2 p
                    updatedbuffer = replaceAt  (pz, color) index zBuffer
                    updatedras = ras {getZBuffer = updatedbuffer}

                return  (updatedras , shader)           
                
    (AmbientLightShader { getCurrentTri = current_tri, ..}) -> 
        do
            let 
                (px, py, pz)                    = fromVec3 $ multmv current_tri bary_coords 
                color = mult_rgba_d (toVec4 255 255 255 255)  pz
                
                updatedbuffer = replaceAt  (pz, color) index (getAmbientBuffer ras)
                updatedras = ras {getAmbientBuffer = updatedbuffer}
     
            return (updatedras , shader) 

load_directionalshader :: Shader
load_directionalshader =  DirectionalLightShader    {   getModelView       = Vec.identity :: Mat44 Double,
                                                        getViewport        = Vec.identity :: Mat44 Double,
                                                        getProjection      = Vec.identity :: Mat44 Double,
                                                        getMVP             = Vec.identity :: Mat44 Double,
                                                        getTransformM      = Vec.identity :: Mat44 Double,
                                                        getCurrentTri     = Vec.identity :: Mat33 Double
                                                    }       
load_ambientshader :: Shader
load_ambientshader =  AmbientLightShader    {   getModelView       = Vec.identity :: Mat44 Double,
                                                getViewport        = Vec.identity :: Mat44 Double,
                                                getProjection      = Vec.identity :: Mat44 Double,
                                                getMVP             = Vec.identity :: Mat44 Double,
                                                getCurrentTri      = Vec.identity :: Mat33 Double
                                            }     
load_camerashader :: Shader
load_camerashader =  CameraShader {     getModelView       = Vec.identity :: Mat44 Double,
                                        getViewport        = Vec.identity :: Mat44 Double,
                                        getProjection      = Vec.identity :: Mat44 Double,
                                        getMVP             = Vec.identity :: Mat44 Double,
                                        getUniformM       = Vec.identity :: Mat44 Double,
                                        getUniformMIT     = Vec.identity :: Mat44 Double,
                                        getUniformMShadow = Vec.identity :: Mat44 Double,
                                        getCurrentUV      = Vec.fromList $ replicate 2 (toVec3Zeros),
                                        getCurrentTri     = Vec.identity :: Mat33 Double
                                  }       


setup_shader :: Rasteriser -> Shader -> Mat44 Double -> IO Shader
setup_shader rasteriser shader transMVP = case shader of
    DirectionalLightShader _ _ _ _ _ _ -> do
        let (Rasteriser _ _ _ _ screen camera light) = rasteriser

            screen_width    = to_double $ width_i screen
            screen_height   = to_double $ height_i screen
            cam_pos         = position camera
            light_dir       = direction light
            depth_coeff     = 0.0

            ----------- SET UP MVP MATRICES IN SHADER -----------
            shader' = mvp_shader shader depth_coeff  (0) (0) (screen_width) (screen_height )  light_dir center up 0.0
            inv_MVP = invert (transMVP)
            transformM = case inv_MVP of Just invMVP     -> ((multmm (getMVP shader') invMVP) :: Mat44 Double)
                                         Nothing         -> (Vec.identity :: Mat44 Double)
        return $ shader' {getTransformM = transformM} 

    AmbientLightShader _ _ _ _ _  -> do
        let (Rasteriser _ _ _ model screen camera light) = rasteriser
       
       
        let screen_width    = to_double $ width_i screen
            cam_pos         = position camera
            screen_height   = to_double $ height_i screen
            light_dir       = direction light
            depth_coeff     = (-1.0)/(Vec.norm( eye- cam_pos))
        return $ mvp_shader shader depth_coeff (screen_width/8.0) (screen_height/8.0)(screen_width * (3.0/4)) (screen_height *(3.0/4))  eye cam_pos up 0.0
        
        
    CameraShader _ _ _ _ _ _ _ _ _ -> do
        let (Rasteriser _ _ _ _ screen camera light) = rasteriser

            screen_width    = to_double $ width_i screen
            screen_height   = to_double $ height_i screen
            light_dir       = direction light
        
            cam_pos         = position camera

        let cam_dir         = rotation camera
            cam_rotation    = (Vec.identity :: Mat44 Double) --rotation camera
            depth_coeff     = if Vec.norm(cam_pos - center) <= (-1.0) then (-1.0) else (-1.0)/(Vec.norm(cam_pos - center))

            ----------- SET UP MVP MATRICES IN SHADER -----------
            shade' = mvp_shader shader (depth_coeff) (0) (0) (screen_width) (screen_height ) cam_pos cam_dir up cam_rotation

            uniform_M = getModelView shade'
            
            inv_MV = invert (multmm (getProjection shade') uniform_M)
            uniform_MIT = case inv_MV of Just invProjMod -> (transpose invProjMod :: Mat44 Double)
                                         Nothing         -> (Vec.identity :: Mat44 Double)

            inv_MVP = invert (getMVP shade')
            uniform_MShadow = case inv_MVP of Just invMVP     -> ((multmm transMVP invMVP) :: Mat44 Double)
                                              Nothing         -> (Vec.identity :: Mat44 Double)

        return shade' {getUniformM = uniform_M, getUniformMIT = uniform_MIT, getUniformMShadow = uniform_MShadow}