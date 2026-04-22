"""
Verify YOLO dataset structure
"""

import os

# EDIT THIS to your dataset path
DATASET_PATH = r'C:\Users\matth\Documents\404CNN\NODYOLO'

def verify_yolo_dataset(path):
    print(f"Checking dataset at: {path}\n")
    
    # Check for yaml file
    yaml_files = [f for f in os.listdir(path) if f.endswith(('.yaml', '.yml'))]
    print(f"YAML config files found: {yaml_files}")
    
    # Check for common folder structures
    possible_train = ['train', 'training']
    possible_val = ['valid', 'val', 'validation', 'test']
    
    found_train = None
    found_val = None
    
    for folder in os.listdir(path):
        folder_lower = folder.lower()
        if folder_lower in possible_train:
            found_train = folder
        elif folder_lower in possible_val:
            found_val = folder
    
    print(f"\nTrain folder: {found_train}")
    print(f"Val folder: {found_val}")
    
    # Check train structure
    if found_train:
        train_path = os.path.join(path, found_train)
        train_images = os.path.join(train_path, 'images')
        train_labels = os.path.join(train_path, 'labels')
        
        if os.path.exists(train_images):
            num_images = len([f for f in os.listdir(train_images) if f.lower().endswith(('.jpg', '.jpeg', '.png'))])
            print(f"  Train images: {num_images}")
        else:
            print(f"  WARNING: {train_images} not found")
        
        if os.path.exists(train_labels):
            num_labels = len([f for f in os.listdir(train_labels) if f.endswith('.txt')])
            print(f"  Train labels: {num_labels}")
        else:
            print(f"  WARNING: {train_labels} not found")
    
    # Check val structure
    if found_val:
        val_path = os.path.join(path, found_val)
        val_images = os.path.join(val_path, 'images')
        val_labels = os.path.join(val_path, 'labels')
        
        if os.path.exists(val_images):
            num_images = len([f for f in os.listdir(val_images) if f.lower().endswith(('.jpg', '.jpeg', '.png'))])
            print(f"  Val images: {num_images}")
        
        if os.path.exists(val_labels):
            num_labels = len([f for f in os.listdir(val_labels) if f.endswith('.txt')])
            print(f"  Val labels: {num_labels}")
    
    # Show sample label file
    if found_train:
        labels_path = os.path.join(path, found_train, 'labels')
        if os.path.exists(labels_path):
            label_files = [f for f in os.listdir(labels_path) if f.endswith('.txt')]
            if label_files:
                sample_label = os.path.join(labels_path, label_files[0])
                print(f"\nSample label file ({label_files[0]}):")
                with open(sample_label, 'r') as f:
                    content = f.read().strip()
                    print(f"  {content[:200]}")
    
    # Show yaml content if exists
    if yaml_files:
        yaml_path = os.path.join(path, yaml_files[0])
        print(f"\nYAML config ({yaml_files[0]}):")
        with open(yaml_path, 'r') as f:
            print(f.read())


if __name__ == '__main__':
    verify_yolo_dataset(DATASET_PATH)