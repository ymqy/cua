// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cua AI, Inc.

use image::{imageops::FilterType, RgbImage};
#[cfg(test)]
use image::Rgb;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Letterbox {
    pub original_width: u32,
    pub original_height: u32,
    pub input_width: u32,
    pub input_height: u32,
    pub resized_width: u32,
    pub resized_height: u32,
    pub pad_x: u32,
    pub pad_y: u32,
    pub scale_x: f32,
    pub scale_y: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ImageTensor {
    pub shape: [usize; 4],
    pub data: Vec<f32>,
    pub letterbox: Letterbox,
}

pub fn detector_tensor(image: &RgbImage, width: u32, height: u32) -> ImageTensor {
    let (original_width, original_height) = image.dimensions();
    let scale = (width as f32 / original_width as f32).min(height as f32 / original_height as f32);
    let resized_width = ((original_width as f32 * scale).round() as u32).clamp(1, width);
    let resized_height = ((original_height as f32 * scale).round() as u32).clamp(1, height);
    let pad_x = (width - resized_width) / 2;
    let pad_y = (height - resized_height) / 2;
    let resized =
        image::imageops::resize(image, resized_width, resized_height, FilterType::Triangle);

    let w_usize = width as usize;
    let h_usize = height as usize;
    let plane = w_usize * h_usize;
    let fill_val = 114.0_f32 / 255.0;
    let mut data = vec![fill_val; plane * 3];
    let (r_plane, rest) = data.split_at_mut(plane);
    let (g_plane, b_plane) = rest.split_at_mut(plane);

    let rw_usize = resized_width as usize;
    let rh_usize = resized_height as usize;
    let px_usize = pad_x as usize;
    let py_usize = pad_y as usize;
    let raw = resized.as_raw();
    const SCALE: f32 = 1.0 / 255.0;

    for y in 0..rh_usize {
        let dst_row_start = (py_usize + y) * w_usize + px_usize;
        let src_row_start = y * rw_usize * 3;
        let src_row = &raw[src_row_start..src_row_start + rw_usize * 3];
        let r_row = &mut r_plane[dst_row_start..dst_row_start + rw_usize];
        let g_row = &mut g_plane[dst_row_start..dst_row_start + rw_usize];
        let b_row = &mut b_plane[dst_row_start..dst_row_start + rw_usize];
        for (((rgb, r_out), g_out), b_out) in src_row
            .chunks_exact(3)
            .zip(r_row.iter_mut())
            .zip(g_row.iter_mut())
            .zip(b_row.iter_mut())
        {
            *r_out = f32::from(rgb[0]) * SCALE;
            *g_out = f32::from(rgb[1]) * SCALE;
            *b_out = f32::from(rgb[2]) * SCALE;
        }
    }

    let letterbox = Letterbox {
        original_width,
        original_height,
        input_width: width,
        input_height: height,
        resized_width,
        resized_height,
        pad_x,
        pad_y,
        scale_x: resized_width as f32 / original_width as f32,
        scale_y: resized_height as f32 / original_height as f32,
    };
    ImageTensor {
        shape: [1, 3, h_usize, w_usize],
        data,
        letterbox,
    }
}

pub fn ocr_detector_tensor(image: &RgbImage, resize_long: u32) -> ImageTensor {
    let scale = resize_long as f32 / image.width().max(image.height()) as f32;
    let width = round_to_multiple((image.width() as f32 * scale).round() as u32, 128);
    let height = round_to_multiple((image.height() as f32 * scale).round() as u32, 128);
    let resized = image::imageops::resize(image, width, height, FilterType::Triangle);
    let letterbox = Letterbox {
        original_width: image.width(),
        original_height: image.height(),
        input_width: width,
        input_height: height,
        resized_width: width,
        resized_height: height,
        pad_x: 0,
        pad_y: 0,
        scale_x: width as f32 / image.width() as f32,
        scale_y: height as f32 / image.height() as f32,
    };
    ImageTensor {
        shape: [1, 3, height as usize, width as usize],
        data: bgr_chw(
            &resized,
            [0.485, 0.456, 0.406],
            [0.229, 0.224, 0.225],
            1.0 / 255.0,
        ),
        letterbox,
    }
}

pub fn ocr_recognizer_tensor(image: &RgbImage, width: u32, height: u32) -> ImageTensor {
    let scale = (height as f32 / image.height() as f32).min(width as f32 / image.width() as f32);
    let resized_width = ((image.width() as f32 * scale).round() as u32).clamp(1, width);
    let resized = image::imageops::resize(image, resized_width, height, FilterType::Triangle);

    let w_usize = width as usize;
    let h_usize = height as usize;
    let plane = w_usize * h_usize;
    // PP-OCR normalization maps 127.5 to zero. Mid-gray padding (128)
    // therefore represents neutral input rather than solid black content.
    let pad_val = (128.0_f32 / 255.0 - 0.5) / 0.5;
    let mut data = vec![pad_val; plane * 3];
    let (b_plane, rest) = data.split_at_mut(plane);
    let (g_plane, r_plane) = rest.split_at_mut(plane);

    let rw_usize = resized_width as usize;
    let raw = resized.as_raw();
    const SCALE: f32 = 1.0 / 255.0;

    for y in 0..h_usize {
        let dst_row_start = y * w_usize;
        let src_row_start = y * rw_usize * 3;
        let src_row = &raw[src_row_start..src_row_start + rw_usize * 3];
        let b_row = &mut b_plane[dst_row_start..dst_row_start + rw_usize];
        let g_row = &mut g_plane[dst_row_start..dst_row_start + rw_usize];
        let r_row = &mut r_plane[dst_row_start..dst_row_start + rw_usize];
        for (((rgb, b_out), g_out), r_out) in src_row
            .chunks_exact(3)
            .zip(b_row.iter_mut())
            .zip(g_row.iter_mut())
            .zip(r_row.iter_mut())
        {
            *b_out = (f32::from(rgb[2]) * SCALE - 0.5) / 0.5;
            *g_out = (f32::from(rgb[1]) * SCALE - 0.5) / 0.5;
            *r_out = (f32::from(rgb[0]) * SCALE - 0.5) / 0.5;
        }
    }

    let letterbox = Letterbox {
        original_width: image.width(),
        original_height: image.height(),
        input_width: width,
        input_height: height,
        resized_width,
        resized_height: height,
        pad_x: 0,
        pad_y: 0,
        scale_x: scale,
        scale_y: height as f32 / image.height() as f32,
    };
    ImageTensor {
        shape: [1, 3, h_usize, w_usize],
        data,
        letterbox,
    }
}

fn round_to_multiple(value: u32, multiple: u32) -> u32 {
    ((value.max(multiple) + multiple / 2) / multiple * multiple).max(multiple)
}

fn bgr_chw(image: &RgbImage, mean: [f32; 3], std: [f32; 3], scale: f32) -> Vec<f32> {
    channels_chw(image, mean, std, scale, [2, 1, 0])
}

fn channels_chw(
    image: &RgbImage,
    mean: [f32; 3],
    std: [f32; 3],
    scale: f32,
    order: [usize; 3],
) -> Vec<f32> {
    let plane = image.width() as usize * image.height() as usize;
    let mut data = vec![0.0; plane * 3];
    let (p0, rest) = data.split_at_mut(plane);
    let (p1, p2) = rest.split_at_mut(plane);
    let raw = image.as_raw();
    let [o0, o1, o2] = order;
    for (((rgb, out0), out1), out2) in raw
        .chunks_exact(3)
        .zip(p0.iter_mut())
        .zip(p1.iter_mut())
        .zip(p2.iter_mut())
    {
        *out0 = (f32::from(rgb[o0]) * scale - mean[0]) / std[0];
        *out1 = (f32::from(rgb[o1]) * scale - mean[1]) / std[1];
        *out2 = (f32::from(rgb[o2]) * scale - mean[2]) / std[2];
    }
    data
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detector_preprocessing_is_chw_and_letterboxed() {
        let image = RgbImage::from_fn(2, 1, |x, _| {
            if x == 0 {
                Rgb([255, 0, 0])
            } else {
                Rgb([0, 255, 0])
            }
        });
        let tensor = detector_tensor(&image, 4, 4);
        assert_eq!(tensor.shape, [1, 3, 4, 4]);
        assert_eq!(tensor.letterbox.resized_width, 4);
        assert_eq!(tensor.letterbox.resized_height, 2);
        assert_eq!(tensor.letterbox.pad_y, 1);
        assert_eq!(tensor.data.len(), 48);
        assert!((tensor.data[4] - 1.0).abs() < 1e-6);
        assert!((tensor.data[16..32].iter().copied().fold(0.0, f32::max) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn recognizer_padding_is_deterministic() {
        let image = RgbImage::from_pixel(2, 2, Rgb([255, 255, 255]));
        let tensor = ocr_recognizer_tensor(&image, 8, 2);
        assert_eq!(tensor.letterbox.resized_width, 2);
        assert_eq!(tensor.data[0], 1.0);
        assert!((tensor.data[2] - (128.0 / 255.0 - 0.5) / 0.5).abs() < 1e-6);
    }

    #[test]
    fn ocr_detector_uses_bgr_and_resize_long() {
        let image = RgbImage::from_pixel(64, 32, Rgb([255, 0, 0]));
        let tensor = ocr_detector_tensor(&image, 96);
        assert_eq!(tensor.shape, [1, 3, 128, 128]);
        assert!(tensor.data[0] < 0.0, "B channel must receive source blue");
        assert!(
            tensor.data[2 * 128 * 128] > 1.0,
            "R channel must receive source red"
        );
    }
}
