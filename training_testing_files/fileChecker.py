"""
Check exported model files
"""

import os

# Check the runs folder for all exported files
export_dir = 'runs/detect/runs/train/yolov8n_custom_1a2/ weights'

print("Files in weights folder:")
print("="*60)

for file in os.listdir(export_dir):
    filepath = os.path.join(export_dir, file)
    size = os.path.getsize(filepath)
    
    if size > 1024*1024:
        size_str = f"{size/1024/1024:.2f} MB"
    else:
        size_str = f"{size/1024:.2f} KB"
    
    print(f"  {file:30} {size_str:>15}")

print("="*60)

# Check for best.pt
best_pt = os.path.join(export_dir, 'best.pt')
if os.path.exists(best_pt):
    size_mb = os.path.getsize(best_pt) / 1024 / 1024
    print(f"\nbest.pt size: {size_mb:.2f} MB")
    
    if size_mb > 5:
        print("✓ PyTorch model looks correct!")
    else:
        print("✗ PyTorch model seems too small!")