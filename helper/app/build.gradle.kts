plugins {
  alias(libs.plugins.android.application)
}

android {
  namespace = "com.rplay.rplayhub.helper"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.rplay.rplayhub.helper"
    minSdk = 26
    targetSdk = 36
    versionCode = 1
    versionName = "1.0"
  }

  buildTypes {
    release {
      isMinifyEnabled = false
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
  }
  lint {
    checkReleaseBuilds = false
  }
}
