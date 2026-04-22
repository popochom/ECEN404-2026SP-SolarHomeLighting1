"""
Real-Time Person Detection with Firebase Integration
Uses YOLOv8 TFLite model for Raspberry Pi deployment
"""

import cv2
import numpy as np
import time
import threading
from datetime import datetime

# Firebase
import firebase_admin
from firebase_admin import credentials, db

# TFLite
try:
    from tflite_runtime.interpreter import Interpreter
except ImportError:
    import tensorflow as tf
    Interpreter = tf.lite.Interpreter
    print('using tf.lite')


# ============================================
# CONFIGURATION - EDIT THIS SECTION
# ============================================

CONFIG = {
    # Model settings
    'model_path': 'saved models/yolov8n-1a.tflite',  # Your TFLite model
    'input_size': 320,
    'confidence_threshold': 0.5,
    'iou_threshold': 0.45,
    
    # Class settings (adjust based on your model's data.yaml)
    'person_class_id': 2,  # Class ID for person in your model
    'class_names': ['bycicle', 'car', 'person'],  # Your class names
    
    # Camera settings
    'camera_id': 1,  # 0 for default camera, or camera URL
    'frame_width': 640,
    'frame_height': 480,
    
    # Firebase settings
    'userKey': '8BRff9bNFHPxHjtkJ93Z71WcqYA2',
    'firebase_credentials': 'solar-home-lighting-1-firebase-adminsdk-fbsvc-c06253cf01.json',
    'firebase_database_url': 'https://solar-home-lighting-1-default-rtdb.firebaseio.com/',
    'firebase_path': 'solar_data/users/8BRff9bNFHPxHjtkJ93Z71WcqYA2/sensorData/humanActivity',  # Database path
    
    # Performance settings
    'firebase_update_interval': 5.0,  # Seconds between Firebase updates
    'show_display': True,  # Set False for headless operation
    'show_fps': True,
}


# ============================================
# FIREBASE CLASS
# ============================================

class FirebaseManager:
    """Handles Firebase Realtime Database communication."""
    
    def __init__(self, credentials_path, database_url, db_path):
        self.db_path = db_path
        self.last_state = None
        self.last_update_time = 0
        self.connected = False
        self.storage_bucket = None
        try:
            # Initialize Firebase
            if not firebase_admin._apps:
                cred = credentials.Certificate(credentials_path)
                firebase_admin.initialize_app(cred, {
                    'databaseURL': database_url,
                    'storageBucket': 'solar-home-lighting-1.firebasestorage.app'
                })
            self.ref = db.reference(db_path)
            self.connected = True
            print(f"✓ Firebase connected: {database_url}")
            print(f"  Database path: {db_path}")
            # Storage
            try:
                from firebase_admin import storage
                self.storage_bucket = storage.bucket()
                print(f"✓ Firebase Storage bucket initialized")
            except Exception as e:
                print(f"✗ Firebase Storage init failed: {e}")
                self.storage_bucket = None
            # Initialize with False
            self.update(False)
        except Exception as e:
            print(f"✗ Firebase connection failed: {e}")
            print("  Continuing without Firebase...")
            self.connected = False
    def upload_video(self, local_path, user_key, remote_name=None):
        """Upload a video file to Firebase Storage under recordings/{userKey}/<filename>. Returns True if successful."""
        if not self.storage_bucket:
            print("✗ No Firebase Storage bucket available.")
            return False
        import os
        # Use the local filename (with date/time) as the remote name
        remote_name = remote_name or os.path.basename(local_path)
        remote_path = f"recordings/{user_key}/{remote_name}"
        try:
            blob = self.storage_bucket.blob(remote_path)
            blob.upload_from_filename(local_path)
            blob.make_public()
            print(f"✓ Uploaded video to Firebase Storage: {blob.public_url}")
            return True
        except Exception as e:
            print(f"✗ Video upload failed: {e}")
            return False
    
    def update(self, person_detected, force=False):
        """Update Firebase with detection state."""
        if not self.connected:
            return
        
        current_time = time.time()
        
        # Only update if state changed or forced
        if person_detected != self.last_state or force:
            try:
                # Update the database
                self.ref.set({
                    'detected': person_detected,
                    'timestamp': datetime.now().isoformat(),
                    'unix_timestamp': current_time
                })
                
                self.last_state = person_detected
                self.last_update_time = current_time
                
                status = "PERSON DETECTED" if person_detected else "No person"
                print(f"  Firebase updated: {status}")
                
            except Exception as e:
                print(f"  Firebase update error: {e}")
    
    def update_with_details(self, person_detected, num_persons=0, confidence=0.0):
        """Update Firebase with detailed detection info."""
        if not self.connected:
            return
        
        if person_detected != self.last_state:
            try:
                self.ref.set({
                    'detected': person_detected,
                    'count': num_persons,
                    'max_confidence': round(confidence, 3),
                    'timestamp': datetime.now().isoformat(),
                    'unix_timestamp': time.time()
                })
                
                self.last_state = person_detected
                
            except Exception as e:
                print(f"  Firebase update error: {e}")


# ============================================
# YOLO DETECTOR CLASS
# ============================================

class YOLODetector:
    """YOLOv8 TFLite detector for person detection."""
    
    def __init__(self, model_path, input_size=320, conf_thresh=0.5, iou_thresh=0.45):
        self.input_size = input_size
        self.conf_thresh = conf_thresh
        self.iou_thresh = iou_thresh
        
        # Load TFLite model
        print(f"Loading model: {model_path}")
        self.interpreter = Interpreter(model_path=model_path)
        self.interpreter.allocate_tensors()
        
        # Get input/output details
        self.input_details = self.interpreter.get_input_details()
        self.output_details = self.interpreter.get_output_details()
        
        # Get input shape
        self.input_shape = self.input_details[0]['shape']
        print(f"  Input shape: {self.input_shape}")
        print(f"  Input dtype: {self.input_details[0]['dtype']}")
        print(f"✓ Model loaded successfully")
    
    def preprocess(self, image):
        """Preprocess image for inference."""
        # Store original dimensions
        self.orig_h, self.orig_w = image.shape[:2]
        
        # Resize to model input size
        resized = cv2.resize(image, (self.input_size, self.input_size))
        
        # Convert BGR to RGB
        rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        
        # Normalize to [0, 1]
        normalized = rgb.astype(np.float32) / 255.0
        
        # Add batch dimension
        input_tensor = np.expand_dims(normalized, axis=0)
        
        return input_tensor
    
    def detect(self, image):
        """Run detection on image."""
        # Preprocess
        input_tensor = self.preprocess(image)
        
        # Run inference
        self.interpreter.set_tensor(self.input_details[0]['index'], input_tensor)
        self.interpreter.invoke()
        
        # Get output
        output = self.interpreter.get_tensor(self.output_details[0]['index'])
        
        # Process output
        detections = self.postprocess(output)
        
        return detections
    
    def postprocess(self, output):
        """Process model output to get detections."""
        # YOLOv8 output shape: [1, 4+num_classes, num_detections]
        # Transpose to [num_detections, 4+num_classes]
        output = output[0].T
        
        boxes = []
        scores = []
        class_ids = []
        
        for detection in output:
            # First 4 values: x_center, y_center, width, height
            # Remaining: class scores
            class_scores = detection[4:]
            class_id = np.argmax(class_scores)
            confidence = class_scores[class_id]
            
            if confidence > self.conf_thresh:
                # Extract bbox (model coordinates)
                x_center, y_center, width, height = detection[:4]
                
                # Convert to original image coordinates
                x_center *= self.orig_w
                y_center *= self.orig_h
                width    *= self.orig_w
                height   *= self.orig_h
                
                # Convert to corner format (x1, y1, w, h) for NMS
                x1 = int(x_center - width / 2)
                y1 = int(y_center - height / 2)
                w = int(width)
                h = int(height)
                
                boxes.append([x1, y1, w, h])
                scores.append(float(confidence))
                class_ids.append(int(class_id))
        
        # Apply Non-Maximum Suppression
        detections = []
        if len(boxes) > 0:
            indices = cv2.dnn.NMSBoxes(boxes, scores, self.conf_thresh, self.iou_thresh)
            
            if len(indices) > 0:
                indices = indices.flatten()
                for i in indices:
                    x1, y1, w, h = boxes[i]
                    detections.append({
                        'bbox': [x1, y1, x1 + w, y1 + h],  # x1, y1, x2, y2
                        'confidence': scores[i],
                        'class_id': class_ids[i]
                    })
        
        return detections


# ============================================
# VISUALIZATION
# ============================================

def draw_detections(image, detections, class_names, person_class_id):
    """Draw bounding boxes on image."""
    person_detected = False
    person_count = 0
    max_confidence = 0.0
    
    for det in detections:
        class_id = det['class_id']
        confidence = det['confidence']
        x1, y1, x2, y2 = det['bbox']
        
        # Check if person
        is_person = (class_id == person_class_id)
        
        if is_person:
            person_detected = True
            person_count += 1
            max_confidence = max(max_confidence, confidence)
            
            # Green color for persons
            color = (0, 255, 0)
            thickness = 3
        else:
            # Gray color for other classes
            color = (128, 128, 128)
            thickness = 1
        
        # Draw bounding box
        cv2.rectangle(image, (x1, y1), (x2, y2), color, thickness)
        
        # Draw label
        class_name = class_names[class_id] if class_id < len(class_names) else f"class_{class_id}"
        label = f"{class_name}: {confidence:.2f}"
        
        # Label background
        (label_w, label_h), baseline = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
        cv2.rectangle(image, (x1, y1 - label_h - 10), (x1 + label_w, y1), color, -1)
        
        # Label text
        cv2.putText(image, label, (x1, y1 - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
    
    # Draw status bar
    status_color = (0, 255, 0) if person_detected else (0, 0, 255)
    status_text = f"PERSON DETECTED ({person_count})" if person_detected else "NO PERSON"
    
    cv2.rectangle(image, (0, 0), (image.shape[1], 40), status_color, -1)
    cv2.putText(image, status_text, (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
    
    return image, person_detected, person_count, max_confidence


def draw_fps(image, fps):
    """Draw FPS counter."""
    fps_text = f"FPS: {fps:.1f}"
    cv2.putText(image, fps_text, (image.shape[1] - 120, 30), 
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)


# ============================================
# MAIN APPLICATION
# ============================================

def main():
    print("="*60)
    print("PERSON DETECTION WITH FIREBASE")
    print("="*60)
    
    # Initialize detector
    print("\n[1/3] Loading YOLO model...")
    detector = YOLODetector(
        model_path=CONFIG['model_path'],
        input_size=CONFIG['input_size'],
        conf_thresh=CONFIG['confidence_threshold'],
        iou_thresh=CONFIG['iou_threshold']
    )
    
    # Initialize Firebase
    print("\n[2/3] Connecting to Firebase...")
    firebase = FirebaseManager(
        credentials_path=CONFIG['firebase_credentials'],
        database_url=CONFIG['firebase_database_url'],
        db_path=CONFIG['firebase_path']
    )
    
    # Initialize camera
    print("\n[3/3] Opening camera...")
    cap = cv2.VideoCapture(CONFIG['camera_id'])
    
    if not cap.isOpened():
        print("✗ Failed to open camera!")
        return
    
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, CONFIG['frame_width'])
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, CONFIG['frame_height'])
    
    actual_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"✓ Camera opened: {actual_width}x{actual_height}")
    
    print("\n" + "="*60)
    print("RUNNING - Press 'q' to quit")
    print("="*60 + "\n")
    
    # FPS calculation
    fps = 0
    frame_count = 0
    start_time = time.time()
    
    # Firebase update timing
    last_firebase_update = 0
    
    # Video recording state
    recording = False
    video_writer = None
    video_filename = None
    last_person_time = 0
    record_fps = 20.0
    record_codec = cv2.VideoWriter_fourcc(*'mp4v')
    import os
    
    user_key = CONFIG.get('userKey', 'unknown')
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                print("Failed to read frame")
                break
            detections = detector.detect(frame)
            frame, person_detected, person_count, max_conf = draw_detections(
                frame, detections, CONFIG['class_names'], CONFIG['person_class_id']
            )
            current_time = time.time()
            # --- Recording logic ---
            if person_detected:
                last_person_time = current_time
                if not recording:
                    video_filename = f"activity_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
                    video_writer = cv2.VideoWriter(
                        video_filename,
                        record_codec,
                        record_fps,
                        (frame.shape[1], frame.shape[0])
                    )
                    recording = True
                    print(f"Started recording: {video_filename}")
                if video_writer:
                    video_writer.write(frame)
            else:
                if recording and (current_time - last_person_time >= 5.0):
                    print(f"Stopping recording: {video_filename}")
                    if video_writer:
                        video_writer.release()
                        video_writer = None
                    recording = False
                    if os.path.exists(video_filename):
                        print(f"Uploading {video_filename} to Firebase Storage...")
                        upload_success = firebase.upload_video(video_filename, user_key)
                        if upload_success:
                            try:
                                os.remove(video_filename)
                                print(f"Deleted local video: {video_filename}")
                            except Exception as e:
                                print(f"Failed to delete local video: {e}")
            # --- End recording logic ---
            if current_time - last_firebase_update >= CONFIG['firebase_update_interval']:
                firebase.update_with_details(person_detected, person_count, max_conf)
                last_firebase_update = current_time
            frame_count += 1
            elapsed = time.time() - start_time
            if elapsed >= 1.0:
                fps = frame_count / elapsed
                frame_count = 0
                start_time = time.time()
            if CONFIG['show_fps']:
                draw_fps(frame, fps)
            if CONFIG['show_display']:
                cv2.imshow('Person Detection', frame)
                key = cv2.waitKey(1) & 0xFF
                if key == ord('q'):
                    print("\nQuitting...")
                    break
                elif key == ord('s'):
                    filename = f"screenshot_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jpg"
                    cv2.imwrite(filename, frame)
                    print(f"Screenshot saved: {filename}")
    except KeyboardInterrupt:
        print("\nInterrupted by user")
    finally:
        print("\nCleaning up...")
        cap.release()
        cv2.destroyAllWindows()
        if video_writer:
            video_writer.release()
        firebase.update(False, force=True)
        print("Done!")

if __name__ == '__main__':
    main()