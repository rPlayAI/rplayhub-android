plugins {
  alias(libs.plugins.android.application)
}

android {
  namespace = "ai.rplay.rplayhub.share"
  compileSdk = 36

  defaultConfig {
    applicationId = "ai.rplay.rplayhub.share"
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
