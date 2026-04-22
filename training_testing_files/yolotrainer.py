"""
YOLOv8n GPU Training
"""

from ultralytics import YOLO
import torch
import os

# ============================================
# EDIT THIS SECTION
# ============================================

DATA_YAML = r"C:\Users\matth\Documents\404CNN\NOD YOLO - v7\data.yaml"  # Your data.yaml path
EPOCHS = 60
IMG_SIZE = 320
BATCH_SIZE = 16  # Increase to 32 if you have enough GPU memory

# ============================================
# TRAINING
# ============================================

def main():
    # GPU Check
    print("="*60)
    if torch.cuda.is_available():
        print(f"✓ GPU: {torch.cuda.get_device_name(0)}")
        print(f"✓ VRAM: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")
        device = 0
    else:
        print("✗ No GPU - Training will be SLOW!")
        device = 'cpu'
    print("="*60)
    
    # Check data.yaml
    if not os.path.exists(DATA_YAML):
        print(f"\nERROR: File not found: {DATA_YAML}")
        print("Please update the DATA_YAML path in this script.")
        return
    
    # Load model
    print(f"\nLoading YOLOv8n...")
    model = YOLO(r"yolov8n.pt")  # Load a YOLOv8n model
    
    # Train
    print(f"\nStarting training...")
    print(f"  Epochs: {EPOCHS}")
    print(f"  Image size: {IMG_SIZE}")
    print(f"  Batch size: {BATCH_SIZE}")
    print()
    
    model.train(
        data=DATA_YAML,
        epochs=EPOCHS,
        imgsz=IMG_SIZE,
        batch=BATCH_SIZE,
        device=device,

        workers=0, # Set to 0 for Windows to avoid issues

        patience=20,
        save=True,
        plots=True,
        amp=True,       # Mixed precision (faster)
        cache=False,     # Cache images (faster). set to false to prevent memory issues
        project='runs/train',
        name='yolov8n_custom_2a'
    )
    
    # Evaluate
    print("\nEvaluating...")
    metrics = model.val()
    print(f"\n  mAP50:    {metrics.box.map50:.4f}")
    print(f"  mAP50-95: {metrics.box.map:.4f}")
    
    # Export to TFLite
    print("\nExporting to TFLite...")
    tflite_path = model.export(format='tflite', imgsz=IMG_SIZE)
    
    # Summary
    print("\n" + "="*60)
    print("TRAINING COMPLETE!")
    print("="*60)
    print(f"Best model:   runs/train/yolov8n_v7g/weights/best.pt")
    print(f"TFLite model: {tflite_path}")
    print("="*60)


if __name__ == '__main__':
    main()