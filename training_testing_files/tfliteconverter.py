"""
Properly export to TFLite
"""

from ultralytics import YOLO
import os

# Load best model
model_path = 'runs/detect/runs/train/yolov8n_custom_1a2/weights/best.pt'
print(f"Loading model from: {model_path}")
print(f"Model file size: {os.path.getsize(model_path)/1024/1024:.2f} MB")

model = YOLO(model_path)

# Export to TFLite
print("\nExporting to TFLite...")
tflite_path = model.export(
    format='tflite',
    imgsz=320,
    int8=False  # FP32 first, easier to export
)

print(f"\nExport complete!")
print(f"TFLite path: {tflite_path}")

# Check the exported file size
if os.path.exists(tflite_path):
    size_mb = os.path.getsize(tflite_path) / 1024 / 1024
    print(f"TFLite size: {size_mb:.2f} MB")
    
    if size_mb > 3:
        print("✓ Export successful!")
    else:
        print("✗ File too small - export may have failed")
else:
    print("✗ TFLite file not found!")
    
    # Look for it
    print("\nSearching for TFLite files...")
    for root, dirs, files in os.walk('runs'):
        for file in files:
            if file.endswith('.tflite'):
                full_path = os.path.join(root, file)
                size = os.path.getsize(full_path) / 1024 / 1024
                print(f"  Found: {full_path} ({size:.2f} MB)")