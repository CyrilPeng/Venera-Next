// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

#include "handles.h"
#include <jni.h>
#include <climits>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>

namespace {
std::atomic<JavaVM *> runtime_vm{nullptr};
jclass api_class = nullptr;
jmethodID metadata_method = nullptr;
jmethodID open_method = nullptr;
std::mutex api_mutex;

struct Environment {
  JavaVM *vm = runtime_vm.load(std::memory_order_acquire);
  JNIEnv *env = nullptr;
  bool attached = false;
  Environment() {
    if (!vm) return;
    const jint result = vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
      attached = vm->AttachCurrentThread(&env, nullptr) == JNI_OK;
      if (!attached) env = nullptr;
    } else if (result != JNI_OK) {
      env = nullptr;
    }
  }
  ~Environment() { if (attached) vm->DetachCurrentThread(); }
};

template<class T> struct LocalReference {
  JNIEnv *env; T value;
  LocalReference(JNIEnv *env, T value) : env(env), value(value) {}
  ~LocalReference() { if (value) env->DeleteLocalRef(value); }
};

std::string exception_text(JNIEnv *env) {
  if (!env->ExceptionCheck()) return "Document provider did not return a file descriptor";
  LocalReference<jthrowable> exception(env, env->ExceptionOccurred());
  env->ExceptionClear();
  if (!exception.value) return "Document-provider operation failed";
  LocalReference<jclass> type(env, env->GetObjectClass(exception.value));
  if (!type.value) { env->ExceptionClear(); return "Document-provider operation failed"; }
  const jmethodID method = env->GetMethodID(type.value, "toString", "()Ljava/lang/String;");
  if (!method) { env->ExceptionClear(); return "Document-provider operation failed"; }
  LocalReference<jstring> text(env, static_cast<jstring>(env->CallObjectMethod(exception.value, method)));
  if (env->ExceptionCheck() || !text.value) {
    env->ExceptionClear(); return "Document-provider operation failed";
  }
  LocalReference<jclass> string_type(env, env->FindClass("java/lang/String"));
  if (!string_type.value) { env->ExceptionClear(); return "Document-provider operation failed"; }
  const jmethodID get_bytes = env->GetMethodID(string_type.value, "getBytes", "(Ljava/lang/String;)[B");
  if (!get_bytes) { env->ExceptionClear(); return "Document-provider operation failed"; }
  // Only the ASCII charset constant uses NewStringUTF. User paths and returned
  // Unicode messages cross JNI as ordinary UTF-8 byte arrays.
  LocalReference<jstring> charset(env, env->NewStringUTF("UTF-8"));
  if (!charset.value) { env->ExceptionClear(); return "Document-provider operation failed"; }
  LocalReference<jbyteArray> bytes(env, static_cast<jbyteArray>(env->CallObjectMethod(text.value, get_bytes, charset.value)));
  if (env->ExceptionCheck() || !bytes.value) {
    env->ExceptionClear(); return "Document-provider operation failed";
  }
  std::string result(static_cast<size_t>(env->GetArrayLength(bytes.value)), '\0');
  env->GetByteArrayRegion(bytes.value, 0, static_cast<jsize>(result.size()), reinterpret_cast<jbyte *>(result.data()));
  if (env->ExceptionCheck()) { env->ExceptionClear(); return "Document-provider operation failed"; }
  return result;
}

void set_error(char **output, const std::string &message) {
  if (!output) return;
  *output = static_cast<char *>(std::malloc(message.size() + 1));
  if (*output) std::memcpy(*output, message.c_str(), message.size() + 1);
}

struct Api { jclass type; jmethodID metadata; jmethodID open; jmethodID get_fd; jmethodID close; jmethodID check; };
jmethodID get_fd_method = nullptr;
jmethodID close_method = nullptr;
jmethodID check_method = nullptr;
Api api_snapshot() {
  std::lock_guard<std::mutex> lock(api_mutex);
  return {api_class, metadata_method, open_method, get_fd_method, close_method, check_method};
}

struct LocalFile {
  JNIEnv *env;
  jobject file;
  jmethodID close;
  bool owned = true;
  ~LocalFile() {
    if (owned) {
      env->CallVoidMethod(file, close);
      if (env->ExceptionCheck()) env->ExceptionClear();
    }
  }
};

struct GlobalFile {
  jobject reference;
  jmethodID close;
  jmethodID check;
};

void close_provider(int, void *owner, std::string *error) noexcept {
  std::unique_ptr<GlobalFile> file(static_cast<GlobalFile *>(owner));
  Environment runtime;
  auto *env = runtime.env;
  if (!env) {
    // Do not independently close a descriptor still owned by a Java object:
    // a later Java close could otherwise close a reused OS descriptor.
    if (error) { try { *error = "Java runtime is unavailable while closing provider file"; } catch (...) {} }
    return;
  }
  try {
    std::string message;
    env->CallVoidMethod(file->reference, file->check);
    if (env->ExceptionCheck()) message = exception_text(env);
    env->CallVoidMethod(file->reference, file->close);
    if (env->ExceptionCheck()) {
      const std::string close_error = exception_text(env);
      if (message.empty()) message = close_error;
    }
    if (error) *error = std::move(message);
  } catch (...) {
    env->ExceptionClear();
    env->CallVoidMethod(file->reference, file->close);
    if (env->ExceptionCheck()) env->ExceptionClear();
  }
  env->DeleteGlobalRef(file->reference);
}
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  runtime_vm.store(vm, std::memory_order_release);
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL
Java_com_cyrilpeng_venera_1saf_NativeBridge_initialize(JNIEnv *env, jclass, jclass type) try {
  std::lock_guard<std::mutex> lock(api_mutex);
  if (api_class) return;
  const auto global = static_cast<jclass>(env->NewGlobalRef(type));
  if (!global) return;
  const auto metadata = env->GetStaticMethodID(global, "metadata", "([B)[B");
  if (!metadata) { env->DeleteGlobalRef(global); return; }
  const auto open = env->GetStaticMethodID(global, "openDescriptor", "([BI)Landroid/os/ParcelFileDescriptor;");
  if (!open) { env->DeleteGlobalRef(global); return; }
  LocalReference<jclass> descriptor(env, env->FindClass("android/os/ParcelFileDescriptor"));
  if (!descriptor.value) { env->DeleteGlobalRef(global); return; }
  const auto get_fd = env->GetMethodID(descriptor.value, "getFd", "()I");
  if (!get_fd) { env->DeleteGlobalRef(global); return; }
  const auto close = env->GetMethodID(descriptor.value, "close", "()V");
  if (!close) { env->DeleteGlobalRef(global); return; }
  const auto check = env->GetMethodID(descriptor.value, "checkError", "()V");
  if (!check) { env->DeleteGlobalRef(global); return; }
  api_class = global;
  metadata_method = metadata;
  open_method = open;
  get_fd_method = get_fd;
  close_method = close;
  check_method = check;
} catch (...) {}

extern "C" SAF_EXPORT int32_t venera_saf_metadata(const uint8_t *request, size_t length,
    uint8_t **output, size_t *output_length) {
  if (output) *output = nullptr;
  if (output_length) *output_length = 0;
  if (!request || !length || length > INT_MAX || !output || !output_length) return 2;
  try {
    Environment runtime;
    auto *env = runtime.env;
    const auto api = api_snapshot();
    if (!env || !api.type || !api.metadata) return 1;
    LocalReference<jbyteArray> input(env, env->NewByteArray(static_cast<jsize>(length)));
    if (!input.value) { env->ExceptionClear(); return 4; }
    env->SetByteArrayRegion(input.value, 0, static_cast<jsize>(length), reinterpret_cast<const jbyte *>(request));
    if (env->ExceptionCheck()) { env->ExceptionClear(); return 3; }
    LocalReference<jbyteArray> result(env, static_cast<jbyteArray>(env->CallStaticObjectMethod(api.type, api.metadata, input.value)));
    if (env->ExceptionCheck() || !result.value) { env->ExceptionClear(); return 3; }
    const jsize count = env->GetArrayLength(result.value);
    std::unique_ptr<uint8_t, decltype(&std::free)> bytes(
        static_cast<uint8_t *>(std::malloc(static_cast<size_t>(count))), &std::free);
    if (!bytes) return 4;
    env->GetByteArrayRegion(result.value, 0, count, reinterpret_cast<jbyte *>(bytes.get()));
    if (env->ExceptionCheck()) { env->ExceptionClear(); return 3; }
    *output_length = static_cast<size_t>(count);
    *output = bytes.release();
    return 0;
  } catch (...) { return 4; }
}

extern "C" SAF_EXPORT uint64_t *venera_saf_open(const uint8_t *path, size_t length,
    int32_t mode, char **error) {
  if (error) *error = nullptr;
  if (!path || !length || length > INT_MAX || mode < 0 || mode > 4) return nullptr;
  try {
    Environment runtime;
    auto *env = runtime.env;
    const auto api = api_snapshot();
    if (!env || !api.type || !api.open || !api.get_fd || !api.close || !api.check) {
      set_error(error, "Native document-provider bridge is not initialized"); return nullptr;
    }
    LocalReference<jbyteArray> input(env, env->NewByteArray(static_cast<jsize>(length)));
    if (!input.value) {
      env->ExceptionClear(); set_error(error, "Unable to allocate provider path"); return nullptr;
    }
    env->SetByteArrayRegion(input.value, 0, static_cast<jsize>(length), reinterpret_cast<const jbyte *>(path));
    if (env->ExceptionCheck()) { set_error(error, exception_text(env)); return nullptr; }
    LocalReference<jobject> file(env, env->CallStaticObjectMethod(api.type, api.open, input.value, mode));
    if (env->ExceptionCheck() || !file.value) {
      set_error(error, exception_text(env)); return nullptr;
    }
    LocalFile local_file{env, file.value, api.close};
    const jint descriptor = env->CallIntMethod(file.value, api.get_fd);
    if (env->ExceptionCheck() || descriptor < 0) {
      set_error(error, exception_text(env));
      return nullptr;
    }
    auto *owner = new (std::nothrow) GlobalFile{env->NewGlobalRef(file.value), api.close, api.check};
    if (!owner || !owner->reference) {
      env->ExceptionClear();
      delete owner;
      set_error(error, "Unable to retain Java provider descriptor");
      return nullptr;
    }
    local_file.owned = false;
    uint64_t *payload = saf_take_provider_descriptor(descriptor, owner, close_provider);
    if (!payload) set_error(error, "Unable to retain provider descriptor");
    return payload;
  } catch (...) { return nullptr; }
}
