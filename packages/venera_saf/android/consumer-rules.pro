# JNI resolves these methods by their reviewed class names and signatures.
-keep class com.cyrilpeng.venera_saf.NativeBridge { *; }
-keep class com.cyrilpeng.venera_saf.SafDocuments {
    public static byte[] metadata(byte[]);
    public static android.os.ParcelFileDescriptor openDescriptor(byte[], int);
}
