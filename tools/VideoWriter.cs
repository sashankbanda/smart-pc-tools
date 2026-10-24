// Writes an H.264 MP4 from raw 32-bit BGRA frames using Windows' built-in Media Foundation
// encoder - nothing to install. Used by make-tutorial.ps1. C# 5 (Windows PowerShell Add-Type).

using System;
using System.Runtime.InteropServices;

namespace TutorialVideo
{
    // Only the slots up to the methods we call need to exist; the order must match mfobjects.h.
    [ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFAttributes
    {
        void GetItem(); void GetItemType(); void CompareItem(); void Compare(); void GetUINT32(); void GetUINT64();
        void GetDouble(); void GetGUID(); void GetStringLength(); void GetString(); void GetAllocatedString();
        void GetBlobSize(); void GetBlob(); void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem();
        void DeleteAllItems();
        void SetUINT32([In] ref Guid guidKey, uint unValue);
        void SetUINT64([In] ref Guid guidKey, ulong unValue);
        void SetDouble();
        void SetGUID([In] ref Guid guidKey, [In] ref Guid guidValue);
        void SetString(); void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount();
        void GetItemByIndex(); void CopyAllItems();
    }

    [ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaType
    {
        void GetItem(); void GetItemType(); void CompareItem(); void Compare(); void GetUINT32(); void GetUINT64();
        void GetDouble(); void GetGUID(); void GetStringLength(); void GetString(); void GetAllocatedString();
        void GetBlobSize(); void GetBlob(); void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem();
        void DeleteAllItems();
        void SetUINT32([In] ref Guid guidKey, uint unValue);
        void SetUINT64([In] ref Guid guidKey, ulong unValue);
        void SetDouble();
        void SetGUID([In] ref Guid guidKey, [In] ref Guid guidValue);
        void SetString(); void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount();
        void GetItemByIndex(); void CopyAllItems();
        // IMFMediaType
        void GetMajorType(); void IsCompressedFormat(); void IsEqual(); void GetRepresentation(); void FreeRepresentation();
    }

    [ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaBuffer
    {
        void Lock(out IntPtr ppbBuffer, out int pcbMaxLength, out int pcbCurrentLength);
        void Unlock();
        void GetCurrentLength(out int pcbCurrentLength);
        void SetCurrentLength(int cbCurrentLength);
        void GetMaxLength(out int pcbMaxLength);
    }

    [ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSample
    {
        void GetItem(); void GetItemType(); void CompareItem(); void Compare(); void GetUINT32(); void GetUINT64();
        void GetDouble(); void GetGUID(); void GetStringLength(); void GetString(); void GetAllocatedString();
        void GetBlobSize(); void GetBlob(); void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem();
        void DeleteAllItems(); void SetUINT32(); void SetUINT64(); void SetDouble(); void SetGUID(); void SetString();
        void SetBlob(); void SetUnknown(); void LockStore(); void UnlockStore(); void GetCount(); void GetItemByIndex();
        void CopyAllItems();
        // IMFSample
        void GetSampleFlags(); void SetSampleFlags();
        void GetSampleTime();
        void SetSampleTime(long hnsSampleTime);
        void GetSampleDuration();
        void SetSampleDuration(long hnsSampleDuration);
        void GetBufferCount(); void GetBufferByIndex(); void ConvertToContiguousBuffer();
        void AddBuffer(IMFMediaBuffer pBuffer);
        void RemoveBufferByIndex(); void RemoveAllBuffers(); void GetTotalLength(); void CopyToBuffer();
    }

    [ComImport, Guid("3137f1cd-fe5e-4805-a5d8-fb477448cb3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSinkWriter
    {
        void AddStream(IMFMediaType pTargetMediaType, out uint pdwStreamIndex);
        void SetInputMediaType(uint dwStreamIndex, IMFMediaType pInputMediaType, IntPtr pEncodingParameters);
        void BeginWriting();
        void WriteSample(uint dwStreamIndex, IMFSample pSample);
        void SendStreamTick(); void PlaceMarker(); void NotifyEndOfSegment(); void Flush();
        void Finalize_();
    }

    public sealed class Mp4Writer : IDisposable
    {
        [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFStartup(uint version, uint flags);
        [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFShutdown();
        [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFCreateMediaType(out IMFMediaType ppMFType);
        [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFCreateSample(out IMFSample ppIMFSample);
        [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFCreateMemoryBuffer(int cbMaxLength, out IMFMediaBuffer ppBuffer);
        [DllImport("mfplat.dll", PreserveSig = false)] static extern void MFCreateAttributes(out IMFAttributes ppMFAttributes, uint cInitialSize);
        [DllImport("mfreadwrite.dll", PreserveSig = false, CharSet = CharSet.Unicode)]
        static extern void MFCreateSinkWriterFromURL(string pwszOutputURL, IntPtr pByteStream, IMFAttributes pAttributes, out IMFSinkWriter ppSinkWriter);

        static Guid MF_MT_MAJOR_TYPE = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
        static Guid MF_MT_SUBTYPE = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
        static Guid MFMediaType_Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
        static Guid MFVideoFormat_H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
        static Guid MFVideoFormat_RGB32 = new Guid("00000016-0000-0010-8000-00AA00389B71");
        static Guid MF_MT_AVG_BITRATE = new Guid("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
        static Guid MF_MT_INTERLACE_MODE = new Guid("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
        static Guid MF_MT_FRAME_SIZE = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
        static Guid MF_MT_FRAME_RATE = new Guid("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
        static Guid MF_MT_PIXEL_ASPECT_RATIO = new Guid("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
        static Guid MF_MT_DEFAULT_STRIDE = new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
        static Guid MF_MT_MPEG2_PROFILE = new Guid("ad76a80b-2d5c-4e0b-b375-64e520137036");
        static Guid MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS = new Guid("a634a91c-822b-41b9-a494-4de4643612b0");
        static Guid MF_SINK_WRITER_DISABLE_THROTTLING = new Guid("08b845d8-2b74-4afe-9d53-be16d2d5ae4f");

        IMFSinkWriter _writer;
        uint _stream;
        readonly int _width, _height, _fps;
        long _frame;
        bool _started;

        public Mp4Writer(string path, int width, int height, int fps, int bitrate)
        {
            _width = width; _height = height; _fps = fps;
            MFStartup(0x00020070, 0);
            _started = true;

            IMFAttributes attributes;
            MFCreateAttributes(out attributes, 2);
            attributes.SetUINT32(ref MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
            attributes.SetUINT32(ref MF_SINK_WRITER_DISABLE_THROTTLING, 1);
            MFCreateSinkWriterFromURL(path, IntPtr.Zero, attributes, out _writer);

            IMFMediaType output;
            MFCreateMediaType(out output);
            output.SetGUID(ref MF_MT_MAJOR_TYPE, ref MFMediaType_Video);
            output.SetGUID(ref MF_MT_SUBTYPE, ref MFVideoFormat_H264);
            output.SetUINT32(ref MF_MT_AVG_BITRATE, (uint)bitrate);
            output.SetUINT32(ref MF_MT_INTERLACE_MODE, 2);   // progressive
            output.SetUINT32(ref MF_MT_MPEG2_PROFILE, 77);   // H.264 Main
            output.SetUINT64(ref MF_MT_FRAME_SIZE, ((ulong)(uint)width << 32) | (uint)height);
            output.SetUINT64(ref MF_MT_FRAME_RATE, ((ulong)(uint)fps << 32) | 1);
            output.SetUINT64(ref MF_MT_PIXEL_ASPECT_RATIO, (1UL << 32) | 1);
            _writer.AddStream(output, out _stream);

            IMFMediaType input;
            MFCreateMediaType(out input);
            input.SetGUID(ref MF_MT_MAJOR_TYPE, ref MFMediaType_Video);
            input.SetGUID(ref MF_MT_SUBTYPE, ref MFVideoFormat_RGB32);
            input.SetUINT32(ref MF_MT_INTERLACE_MODE, 2);
            input.SetUINT32(ref MF_MT_DEFAULT_STRIDE, (uint)(width * 4));   // top-down rows
            input.SetUINT64(ref MF_MT_FRAME_SIZE, ((ulong)(uint)width << 32) | (uint)height);
            input.SetUINT64(ref MF_MT_FRAME_RATE, ((ulong)(uint)fps << 32) | 1);
            input.SetUINT64(ref MF_MT_PIXEL_ASPECT_RATIO, (1UL << 32) | 1);
            _writer.SetInputMediaType(_stream, input, IntPtr.Zero);
            _writer.BeginWriting();
        }

        // pixels: width*height*4 bytes, BGRA, top row first.
        public void WriteFrame(byte[] pixels)
        {
            int length = _width * _height * 4;
            IMFMediaBuffer buffer;
            MFCreateMemoryBuffer(length, out buffer);
            IntPtr data; int max, current;
            buffer.Lock(out data, out max, out current);
            Marshal.Copy(pixels, 0, data, length);
            buffer.Unlock();
            buffer.SetCurrentLength(length);

            IMFSample sample;
            MFCreateSample(out sample);
            sample.AddBuffer(buffer);
            long duration = 10000000L / _fps;
            sample.SetSampleTime(_frame * duration);
            sample.SetSampleDuration(duration);
            _writer.WriteSample(_stream, sample);
            _frame++;
            Marshal.ReleaseComObject(sample);
            Marshal.ReleaseComObject(buffer);
        }

        public long Frames { get { return _frame; } }

        public void Dispose()
        {
            if (_writer != null) { _writer.Finalize_(); Marshal.ReleaseComObject(_writer); _writer = null; }
            if (_started) { MFShutdown(); _started = false; }
        }
    }
}
