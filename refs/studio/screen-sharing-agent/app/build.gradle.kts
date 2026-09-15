plugins {
  alias(libs.plugins.android.application)
}

android {
    // The NDK varies by build host and sdkDownload is off, so a single pinned version breaks
    // whichever host does not have it installed. tools/build-agent.sh passes the NDK installed
    // locally as -PrplayhubNdkVersion; a bare gradle run keeps the Linux build host's version.
    ndkVersion = (findProperty("rplayhubNdkVersion") as String?) ?: "27.0.12077973"
  namespace = "com.android.tools.screensharing"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.android.tools.screensharing"
    minSdk = 26
    targetSdk = 36
    versionCode = 1
    versionName = "1.0"

    externalNativeBuild {
      cmake {
        cppFlags += "-std=c++20"
      }
    }
  }

  buildTypes {
    release {
      isMinifyEnabled = false
      proguardFiles(
        getDefaultProguardFile("proguard-android-optimize.txt"),
        "proguard-rules.pro",
      )
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
  }
  externalNativeBuild {
    cmake {
      path = file("src/main/cpp/CMakeLists.txt")
      version = "3.22.1"
    }
  }
  lint {
    checkReleaseBuilds = false
  }
  buildFeatures {
    aidl = true
  }
}
