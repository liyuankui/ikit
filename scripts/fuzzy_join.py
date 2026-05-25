import json
import csv
from collections import Counter

def load_asr(path):
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    segments = []
    for item in data:
        for sent in item.get('sentence_info', []):
            segments.append({
                'spk': f"SPEAKER_{sent['spk']:02d}",
                'start': sent['start'],
                'end': sent['end'],
                'text': sent['text']
            })
    return segments

def load_ocr(path):
    ocr_results = []
    with open(path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            ocr_results.append({
                'ts': int(row['timestamp_ms']),
                'text': row['ocr_text']
            })
    return ocr_results

def fuzzy_join(asr_segments, ocr_data, window_ms=5000):
    mapping = {} # SPEAKER_ID -> Name
    votes = {}   # SPEAKER_ID -> Counter of names seen
    
    print(f"📊 Analyzing {len(asr_segments)} ASR segments against {len(ocr_data)} OCR frames...\n")

    for seg in asr_segments:
        spk = seg['spk']
        if spk not in votes: votes[spk] = Counter()
        
        # Define search window [start - window, end + window]
        t_min = seg['start'] - window_ms
        t_max = seg['end'] + window_ms
        
        # Find OCR frames in this window
        relevant_frames = [f for f in ocr_data if t_min <= f['ts'] <= t_max]
        
        for frame in relevant_frames:
            # Simple heuristic: Extract common names or look for "正在发言："
            if "正在发言：" in frame['text']:
                name = frame['text'].split("：")[1]
                votes[spk][name] += 1
            elif "Speaker" in frame['text']:
                # Placeholder for other pattern matching
                pass

    # Commit phase
    print("🎯 Mapping Commitment (Threshold > 60%):")
    for spk, counter in votes.items():
        if not counter:
            mapping[spk] = "Unknown"
            print(f"  {spk} -> Unknown (No visual signal)")
            continue
            
        top_name, count = counter.most_common(1)[0]
        total = sum(counter.values())
        confidence = count / total
        
        if confidence >= 0.6:
            mapping[spk] = top_name
            print(f"  ✅ {spk} -> {top_name} (Confidence: {confidence:.2%})")
        else:
            mapping[spk] = f"Probable {top_name}?"
            print(f"  ⚠️ {spk} -> {top_name} (Low Confidence: {confidence:.2%})")
            
    return mapping

if __name__ == "__main__":
    asr = load_asr("cost_saving_output.json")
    ocr = load_ocr("tmp/mock_ocr.csv")
    
    result_map = fuzzy_join(asr, ocr)
    
    # Final Preview: Apply mapping to first few lines
    print("\n📝 Final Transcript Preview:")
    for seg in asr[:5]:
        name = result_map.get(seg['spk'], seg['spk'])
        print(f"[{name}]: {seg['text']}")
