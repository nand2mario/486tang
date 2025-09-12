#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>

class WAVWriter {
private:
    FILE* file;
    uint32_t data_size;
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t bits_per_sample;

    struct WAVHeader {
        // RIFF chunk
        char riff_id[4];        // "RIFF"
        uint32_t riff_size;     // File size - 8
        char wave_id[4];        // "WAVE"
        
        // fmt chunk
        char fmt_id[4];         // "fmt "
        uint32_t fmt_size;      // Size of fmt chunk (16)
        uint16_t format;        // Audio format (1 = PCM)
        uint16_t channels;      // Number of channels
        uint32_t sample_rate;   // Sample rate
        uint32_t byte_rate;     // Byte rate
        uint16_t block_align;   // Block alignment
        uint16_t bits_per_sample; // Bits per sample
        
        // data chunk
        char data_id[4];        // "data"
        uint32_t data_size;     // Size of data
    };

public:
    WAVWriter(const char* filename, uint32_t sample_rate = 48000, uint16_t channels = 2, uint16_t bits_per_sample = 16)
        : file(nullptr), data_size(0), sample_rate(sample_rate), channels(channels), bits_per_sample(bits_per_sample) {
        
        file = fopen(filename, "wb");
        if (!file) {
            printf("Error: Could not open WAV file %s for writing\n", filename);
            return;
        }
        
        // Write placeholder header (will be updated in destructor)
        writeHeader();
    }
    
    ~WAVWriter() {
        if (file) {
            // Update header with final data size
            fseek(file, 0, SEEK_SET);
            writeHeader();
            fclose(file);
            printf("WAV file closed: %d samples written (%.2f seconds)\n", 
                   data_size / (channels * bits_per_sample / 8),
                   (double)data_size / (channels * bits_per_sample / 8) / sample_rate);
        }
    }
    
    void writeSample(int16_t left, int16_t right) {
        if (!file) return;
        
        // Write stereo sample (little-endian)
        fwrite(&left, sizeof(int16_t), 1, file);
        fwrite(&right, sizeof(int16_t), 1, file);
        data_size += 4;  // 2 channels * 2 bytes per sample
    }
    
private:
    void writeHeader() {
        if (!file) return;
        
        WAVHeader header = {};
        
        // RIFF chunk
        memcpy(header.riff_id, "RIFF", 4);
        header.riff_size = 36 + data_size;  // Header size + data size
        memcpy(header.wave_id, "WAVE", 4);
        
        // fmt chunk
        memcpy(header.fmt_id, "fmt ", 4);
        header.fmt_size = 16;
        header.format = 1;  // PCM
        header.channels = channels;
        header.sample_rate = sample_rate;
        header.byte_rate = sample_rate * channels * bits_per_sample / 8;
        header.block_align = channels * bits_per_sample / 8;
        header.bits_per_sample = bits_per_sample;
        
        // data chunk
        memcpy(header.data_id, "data", 4);
        header.data_size = data_size;
        
        fwrite(&header, sizeof(WAVHeader), 1, file);
    }
};