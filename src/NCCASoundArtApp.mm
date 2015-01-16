#include "cinder/app/AppNative.h"
#include "cinder/gl/gl.h"
#include "cinder/ImageIo.h"
#include "cinder/Surface.h"
#include "cinder/gl/Texture.h"
#include "cinder/Capture.h"
#include "cinder/Text.h"
#include "cinder/qtime/QuickTime.h"
#include "cinder/ip/Resize.h"
#include "cinder/System.h"
#include "cinder/Timeline.h"


#include "CinderOpenCv.h"
#include "UVCCameraControl.h"
#include "ciUI.h"
#include "math.h"
#include "OscSender.h"

using namespace ci;
using namespace ci::app;
using namespace std;

static const int WIDTH = 320, HEIGHT = 240;

class NCCASoundArtApp : public AppNative {
  public:
    ~NCCASoundArtApp();
    void prepareSettings( Settings *settings );
	void setup();
    void update();
	void draw();
    void mouseDown( MouseEvent event );
    void mouseMove( MouseEvent event );
    void mouseDrag( MouseEvent event );
    void mouseUp( MouseEvent event );
    void keyDown( KeyEvent event );
    void fileDrop( FileDropEvent event );
    void loadMovieFile( const fs::path &moviePath );
	void perspectiveCorrection();
    void savePointsOfPerspectiveCorrection();
    void loadPointsOfPerspectiveCorrection();
    float sliderTextureToSliderPos();
    void processFrame();
    void guiEvent(ciUIEvent *event);
    
    Vec2i                   mPos;
	gl::TextureRef          mTexture, mTextureCorrected;
    vector<CaptureRef>		mCaptures;
    CaptureRef              mActiveCapture;
    vector<gl::TextureRef>	mTextures;
    vector<gl::TextureRef>	mNameTextures;
	vector<Surface>			mRetainedSurfaces;
    Surface8u               mSurface;
    
    bool                    mShowParams;
    Rectf                   mCapturePreviewSize;
    Vec2f                   mCapturePreviewScaleCoeff;
    cv::Mat                 cvCurrentFrame, cvCurrentFrameCorrected, cvThresholdImage;
    bool                    mIsChangingPerspective;
    int                     mNumberOfDraggedPoint;
    
    // CAMERA CALIBRATION
	bool					isChoosingPoints;
	int						pointsChoosed;
	cv::Point2f				cvCalibSrc[4], cvCalibDst[4];
    
    float					cvThreshold,cvThresConstant, cvThresBlockSizeFloat;
    
    cv::Mat                 cvSliderMat;
    gl::TextureRef          mSliderTexture;
    /*Anim<*/float/*>*/             mSliderPos;
    float                   mSliderPosPrev;
    float                   mAlpha1, mAlpha2;
    bool                    mSliderTouchState;
    
    ciUICanvas              *mGui, *mGui2;
    bool                    mDrawGui;
    
    //MOVIE
    //qtime::MovieGlRef		mMovie;
    qtime::MovieSurfaceRef  mMovie;
    bool                    mPlayMovieInstedOfCapture;
    
    // Camera parameters
    UVCCameraControl *      mCameraControl;
    float                   mExposure;
    
    //OSC
    osc::Sender             mOSCSender,mOSCSender2;
    int                     mOSCPort;
    int                     mOSCPort2;
    string                  mOSCHost;
    
    //DRAW ALL
    bool                    mDraw;

    bool                    mStopDetection;
};

void NCCASoundArtApp::prepareSettings( Settings *settings )
{
    settings->setTitle("SoundArtWorkshop");
}

void NCCASoundArtApp::setup()
{
    mDraw = true;
    mPlayMovieInstedOfCapture = false;
    // list out the devices
	vector<Capture::DeviceRef> devices( Capture::getDevices() );
	for( vector<Capture::DeviceRef>::const_reverse_iterator deviceIt = devices.rbegin(); deviceIt != devices.rend(); ++deviceIt ) {
		Capture::DeviceRef device = *deviceIt;
		console() << "Found Device " << device->getName() << " ID: " << device->getUniqueId() << std::endl;
		try {
			if( device->checkAvailable() ) {
				mCaptures.push_back( Capture::create( WIDTH, HEIGHT, device ) );
                mActiveCapture = mCaptures.back();
				//mCaptures.back()->start();
			}
			else
				console() << "device is NOT available" << std::endl;
		}
		catch( CaptureExc & ) {
			console() << "Unable to initialize device: " << device->getName() << endl;
		}
	}
    
    mActiveCapture->start();
    
    UInt32 locationID = 0;
    Capture::DeviceIdentifier uID = mActiveCapture->getDevice()->getUniqueId();
    sscanf( uID.c_str(), "0x%8x", &locationID );
    printf("Unique ID: %s\n",  uID.c_str() );
    mCameraControl = [[UVCCameraControl alloc] initWithLocationID:locationID];
	[mCameraControl setAutoExposure:YES];
    
    mSliderPos = 0.f;
    mSliderPosPrev = 0.f;
    mSliderTouchState = false;
    
    mCapturePreviewSize = Rectf(0.f, 0.f, 320.f, 240.f );
    mCapturePreviewScaleCoeff = Vec2f( mCapturePreviewSize.x2 / WIDTH, mCapturePreviewSize.y2 / HEIGHT);
    
    cvCalibSrc[0] = cv::Point2f(0.f,0.f);
    cvCalibSrc[1] = cv::Point2f(WIDTH,0.f);
    cvCalibSrc[2] = cv::Point2f(WIDTH,HEIGHT);
    cvCalibSrc[3] = cv::Point2f(0.f,HEIGHT);
    cvCalibDst[0] = cvCalibSrc[0];
    cvCalibDst[1] = cvCalibSrc[1];
    cvCalibDst[2] = cvCalibSrc[2];
    cvCalibDst[3] = cvCalibSrc[3];
    mIsChangingPerspective = false;
    mAlpha1 = 25.f;
    mAlpha2 = 70.f;
    
    cvThreshold = 50.0f;
	cvThresBlockSizeFloat = 177;
	cvThresConstant = 0.14f;
    
    mSurface = Surface8u( WIDTH, HEIGHT, false );
    cvCurrentFrame.create(WIDTH, HEIGHT, CV_8UC1);
    cvCurrentFrameCorrected.create(WIDTH, HEIGHT, CV_8UC1);
    cvThresholdImage.create(WIDTH, HEIGHT, CV_8UC1);
    cvSliderMat.create(WIDTH, 1, CV_8UC1);
    
    //Setup OSC
    mOSCPort  = 3000;
    mOSCPort2 = 3001;
	// assume the broadcast address is this machine's IP address but with 255 as the final value
	// so to multicast from IP 192.168.1.100, the host should be 192.168.1.255
	mOSCHost = System::getIpAddress();
	if( mOSCHost.rfind( '.' ) != string::npos )
		mOSCHost.replace( mOSCHost.rfind( '.' ) + 1, 3, "255" );
	mOSCSender.setup( mOSCHost, mOSCPort, true );
    mOSCSender2.setup( mOSCHost, mOSCPort2, true );

    loadPointsOfPerspectiveCorrection();
    
    int length = 240;
    mGui = new ciUICanvas( 0, mCapturePreviewSize.y2, app::getWindowWidth()/2, mCapturePreviewSize.y2);
    mGui->addWidgetDown( new ciUILabel("CAM CONTROLS", CI_UI_FONT_LARGE), CI_UI_ALIGN_LEFT );
    mGui->addWidgetDown(new ciUISpacer(length, 2), CI_UI_ALIGN_LEFT);
    mGui->addWidgetDown( new ciUIToggle( 15, 15, true, "Auto Exposure" ) );
    mExposure = 0.5f;
    ciUISlider * slider = new ciUISlider(length, 5.f, 0.f, 1.0f, &mExposure, "Value");
    slider->setIncrement( 0.01f );
    slider->setVisible( false );
    mGui->addWidgetDown( slider );
    mGui->addWidgetDown( new ciUILabel("Threshold", CI_UI_FONT_MEDIUM), CI_UI_ALIGN_LEFT );
    mGui->addWidgetDown( new ciUISlider(length, 5.f,  3.f, 719.f, &cvThresBlockSizeFloat, "Block Size") );
        ((ciUISlider *) mGui->getWidget( "Block Size"))->setIncrement( 2.f );
    mGui->addWidgetDown( new ciUISlider(length, 5.f, -1.f, 1.0f, &cvThresConstant, "Constant C")  );
        ((ciUISlider *) mGui->getWidget( "Constant C"))->setIncrement( 0.01f );
    //mGui->setTheme(CI_UI_THEME_MINBLACK);
    mGui->setTheme( 6 );
    
    mGui2 = new ciUICanvas( app::getWindowWidth()/2, mCapturePreviewSize.y2, app::getWindowWidth()/2, mCapturePreviewSize.y2);

    mGui2->addWidgetDown( new ciUILabel("SLIDER", CI_UI_FONT_LARGE), CI_UI_ALIGN_LEFT );
    mGui2->addWidgetDown( new ciUISpacer(length, 2), CI_UI_ALIGN_LEFT);
    mGui2->addWidgetDown( new ciUISlider(length, 5.f,  0.f, 1.f, &mSliderPos/*.ptr()*/, "Sound Pos") );
        ((ciUISlider *) mGui2->getWidget( "Sound Pos"))->setLabelVisible(false);
        ((ciUISlider *) mGui2->getWidget( "Sound Pos"))->setIncrement( 0.01f );
    
    mGui2->addWidgetDown( new ciUITextInput(length - 20, "IP", mOSCHost, CI_UI_FONT_MEDIUM) );
//    mGui2->addWidgetDown( new ciUILabel("Alpha 1     ", CI_UI_FONT_LARGE), CI_UI_ALIGN_LEFT );
//    mGui2->addWidgetRight( new ciUINumberDialer(0.f, 90.f, &mAlpha1, 10, "Alpha_1", CI_UI_FONT_MEDIUM ) );
//    mGui2->addWidgetDown( new ciUILabel("Alpha 2     ", CI_UI_FONT_LARGE), CI_UI_ALIGN_LEFT );
//    mGui2->addWidgetRight( new ciUINumberDialer(0.f, 90.f, &mAlpha2, 10, "Alpha_2", CI_UI_FONT_MEDIUM ) );
    
  //  mGui2->addWidgetDown( new ciUINumberDialer(0.f, 90.f, &mAlpha2, 1, "Alpha 2" ,50 ) );
//    mGui2->addWidgetDown( new ciUILabel("MOVIE", CI_UI_FONT_LARGE), CI_UI_ALIGN_LEFT );
    mGui2->addWidgetDown( new ciUISpacer(length, 2), CI_UI_ALIGN_LEFT);
    mGui2->addWidgetDown(new ciUILabelButton( length/2.1f, false, "OPEN MOVIE", CI_UI_FONT_MEDIUM ) );
    ciUIToggleMatrix* toggleMatrix =  new ciUIToggleMatrix(15, 15, 1, 2, "C M");
    toggleMatrix->setAllowMultiple( false );
    toggleMatrix->setToggleAndTrigger(0, 0, true);
    mGui2->setTheme( 6 );
    mGui2->addWidgetDown( toggleMatrix );


    
    mGui->registerUIEvents(this, &NCCASoundArtApp::guiEvent);
    mGui2->registerUIEvents(this, &NCCASoundArtApp::guiEvent);
    
    mDrawGui = true;
    
}

void NCCASoundArtApp::update() {
    
    if ( mPlayMovieInstedOfCapture && mMovie )
    {
        Surface8u surf = mMovie->getSurface();
        if ( surf )
        {
            ip::resize(  surf, &mSurface );
            if ( mDraw )
                mTexture = gl::Texture::create( mSurface );
            processFrame();
            sliderTextureToSliderPos();
        }
        
    }
    else if( mActiveCapture->checkNewFrame() ) {
        mSurface = mActiveCapture->getSurface();
        if(mDraw) mTexture = gl::Texture::create( mSurface );
        processFrame();
        sliderTextureToSliderPos();
        
    }
    
    if ( mDrawGui ) {
        mGui->update();
        mGui2->update();
    }
    
    // Send Slider Position Message
    osc::Message message;
    message.addFloatArg( mSliderPos/*.value()*/ );
    //    message.setAddress("/cinder/osc/1");
    message.setRemoteEndpoint(mOSCHost, mOSCPort);
    mOSCSender.sendMessage(message);
    
    if ( mSliderPosPrev != mSliderPos/*.value()*/ )
    {
        // Send Slider Position Message
        osc::Message message;
        message.addFloatArg( mSliderPos/*.value()*/ );
        //    message.setAddress("/cinder/osc/1");
        message.setRemoteEndpoint(mOSCHost, mOSCPort);
        mOSCSender.sendMessage(message);
        
        mSliderPosPrev = mSliderPos/*.value()*/;
    }
    

    
    
}
void NCCASoundArtApp::draw()
{
    gl::color( Color::white() );
    if ( !mDraw )
        return
        
	gl::enableAlphaBlending();
	gl::clear( Color::black() );
    
    
    if ( mTexture ) {
        gl::draw( mTexture, mCapturePreviewSize );
        gl::color( 1, 0, 0 );
        gl::drawLine( Vec2f(cvCalibDst[0].x, cvCalibDst[0].y)*mCapturePreviewScaleCoeff , Vec2f(cvCalibDst[1].x, cvCalibDst[1].y)*mCapturePreviewScaleCoeff );
        gl::drawLine( Vec2f(cvCalibDst[1].x, cvCalibDst[1].y)*mCapturePreviewScaleCoeff , Vec2f(cvCalibDst[2].x, cvCalibDst[2].y)*mCapturePreviewScaleCoeff  );
        gl::drawLine( Vec2f(cvCalibDst[2].x, cvCalibDst[2].y)*mCapturePreviewScaleCoeff , Vec2f(cvCalibDst[3].x, cvCalibDst[3].y)*mCapturePreviewScaleCoeff  );
        gl::drawLine( Vec2f(cvCalibDst[3].x, cvCalibDst[3].y)*mCapturePreviewScaleCoeff , Vec2f(cvCalibDst[0].x, cvCalibDst[0].y)*mCapturePreviewScaleCoeff  );
        gl::color( 1, 1, 1 );
    }
    
    if ( mSliderTexture )
        gl::draw( mSliderTexture, mCapturePreviewSize + mCapturePreviewSize.getUpperRight() );
    
    // DRAW PARAMS WINDOW
    if ( mDrawGui ) {
        mGui->draw();
        mGui2->draw();
    }
}

void NCCASoundArtApp::mouseMove( MouseEvent event )
{
    mPos = event.getPos();
}

void NCCASoundArtApp::mouseDown( MouseEvent event ) {
    
    mPos = event.getPos();
    for (int i = 0; i < 4; ++i)
        if ( mPos.distanceSquared( Vec2f(cvCalibDst[i].x, cvCalibDst[i].y)*mCapturePreviewScaleCoeff ) < 65 ) {
            mIsChangingPerspective = true;
            mNumberOfDraggedPoint = i;
            break;
        }
}

void NCCASoundArtApp::mouseDrag( MouseEvent event ) {
    
    mPos = event.getPos();
    
    if ( mIsChangingPerspective ) {
        cvCalibDst[ mNumberOfDraggedPoint ] = cv::Point2f( mPos.x/mCapturePreviewScaleCoeff.x, mPos.y/mCapturePreviewScaleCoeff.y);
        
    }
    

}

void NCCASoundArtApp::mouseUp( MouseEvent event ) {
    
    mIsChangingPerspective = false;
    
}
void NCCASoundArtApp::perspectiveCorrection()
{
	cv::Mat transform = getPerspectiveTransform(cvCalibDst, cvCalibSrc );
	cv::warpPerspective( cvCurrentFrame, cvCurrentFrameCorrected, transform, cv::Size( WIDTH, HEIGHT ), cv::INTER_LINEAR );
}

void NCCASoundArtApp::loadMovieFile( const fs::path &moviePath )
{
	try {
		// load up the movie, set it to loop, and begin playing
		mMovie = qtime::MovieSurface::create( moviePath );
		mMovie->setLoop();
        mMovie->seekToStart();
        if (mPlayMovieInstedOfCapture)
            mMovie->play();
	}
	catch( ... ) {
		console() << "Unable to load the movie." << std::endl;
		mMovie->reset();
//		mInfoTexture.reset();
	}
    
	mTexture.reset();
}

void NCCASoundArtApp::processFrame()
{    
//    Surface8u surf = mActiveCapture->getSurface();
    //Channel8u blueChannel = surf.getChannelBlue();
    cvCurrentFrame = toOcv( mSurface );
    cvCurrentFrame.convertTo( cvCurrentFrame, CV_8UC1 );
    perspectiveCorrection();
    cv::resize(cvCurrentFrameCorrected, cvSliderMat, cv::Size(WIDTH,1) );
    
    cv::cvtColor( cvSliderMat, cvSliderMat, CV_BGR2GRAY);
    //        cvCurrentFrameCorrected.convertTo( cvCurrentFrameCorrected, CV_8UC1 );
    //        cv::threshold(cvCurrentFrameCorrected, cvCurrentFrameCorrected, cvThreshold, 255, CV_THRESH_BINARY);
    cv::adaptiveThreshold(cvSliderMat, cvSliderMat, 255, cv::ADAPTIVE_THRESH_MEAN_C, cv::THRESH_BINARY, (int)round(cvThresBlockSizeFloat), (int) (cvThresConstant*255) );
    mSliderTexture = gl::Texture::create( Channel( fromOcv(cvSliderMat )) );
}

void NCCASoundArtApp::guiEvent(ciUIEvent *event){
    
    string name = event->widget->getName();
    if(name == "Value")
	{
		ciUISlider *slider = (ciUISlider *) event->widget;
        [mCameraControl setExposure: slider->getValue()];
	}
    else if( name == "Auto Exposure")
    {
        ciUIToggle *toggle = (ciUIToggle *) event->widget;
        bool value = toggle->getValue();
        [mCameraControl setAutoExposure: value];
        ciUISlider *slider = (ciUISlider *)mGui->getWidget("Value");
        
        if ( value )
            slider->setVisible( false );
        else
            slider->setVisible( true );
    }
    else if ( name == "OPEN MOVIE" )
    {
        fs::path moviePath = getOpenFilePath();
        if( ! moviePath.empty() )
            loadMovieFile( moviePath );
    }
    else if ( name == "C M(0,1)" )
    {
        mPlayMovieInstedOfCapture = true;
        if (mMovie)
            mMovie->play();
        
        cout<< "Playing Movie" <<endl;
        
        
//        ciUIToggleMatrix *toggleMatrix = (ciUIToggleMatrix *) event->widget;
//        vector< ciUIToggle*> toggles = toggleMatrix->getToggles();
//        printf("Toggles size: %d", (int)toggles.size() );
//        for ( auto& t: toggles )
//            printf("  Toggle value: %d\n", t->getValue() );
//        
//        if ( toggles[0]->getValue() ) {
//            mPlayMovieInstedOfCapture = true;
//            cout<< "Playing Movie" <<endl;
//        }
//        else {
//            mPlayMovieInstedOfCapture = false;
//            cout << "Playing Capture" << endl;
//        }
    }
    else if ( name == "C M(0,0)" )
    {
        mPlayMovieInstedOfCapture = false;
        if (mMovie)
            mMovie->stop();
        
        cout<< "Playing Capture" <<endl;
    }
    else if ( name == "IP" )
    {
        console() << "Setting another IP" << endl;
        ciUITextInput *textInput = (ciUITextInput *) event->widget;
        mOSCHost = textInput->getTextString();
        mOSCSender.setup( mOSCHost, mOSCPort, true );
        mOSCSender2.setup( mOSCHost, mOSCPort2, true );
    }
}

void NCCASoundArtApp::fileDrop( FileDropEvent event )
{
	loadMovieFile( event.getFile( 0 ) );
}

void NCCASoundArtApp::keyDown( KeyEvent event )
{
	if( event.getChar() == 'p' ) {
		float v = sliderTextureToSliderPos();
        printf("Slider pos: %8.6f\n", v );
	}
    else if( event.getChar() == 'l' ) {
		loadPointsOfPerspectiveCorrection();
	}
    else if( event.getChar() == 's' ) {
		savePointsOfPerspectiveCorrection();
	}
    else if( event.getChar() == 'g' )
        mDrawGui = !mDrawGui;
    else if (event.getChar() == 'r' )
    {
        cvCalibDst[0] = cv::Point2f(0.f,0.f);
        cvCalibDst[1] = cv::Point2f(WIDTH,0.f);
        cvCalibDst[2] = cv::Point2f(WIDTH,HEIGHT);
        cvCalibDst[3] = cv::Point2f(0.f,HEIGHT);
    }
    else if (event.getChar() == 'd' )
        mDraw = !mDraw;

}

void NCCASoundArtApp::savePointsOfPerspectiveCorrection()
{
    FILE* file = fopen( (getTemporaryDirectory()/"NCCASoundArtPreferences.bin").c_str(), "w" );
    if (file == NULL)
        return;
    fwrite( &cvCalibDst[0], 4, sizeof(cv::Point2f), file );
    fwrite( &cvThresBlockSizeFloat, 1, sizeof(float), file );
    fwrite( &cvThresConstant, 1, sizeof(float), file );
    fclose(file);
}

void NCCASoundArtApp::loadPointsOfPerspectiveCorrection()
{
    FILE* file = fopen( (getTemporaryDirectory()/"NCCASoundArtPreferences.bin").c_str(), "r" );
    if (file == NULL)
        return;
    fread( &cvCalibDst[0], 4, sizeof(cv::Point2f), file );
    fread( &cvThresBlockSizeFloat, 1, sizeof(float), file );
    fread( &cvThresConstant, 1, sizeof(float), file );
    fclose(file);
}


float NCCASoundArtApp::sliderTextureToSliderPos()
{
    vector< int > pos;
    
    for(int row = 0; row < cvSliderMat.rows; ++row) {
        uchar* p = cvSliderMat.ptr(row);
        for(int col = 0; col < cvSliderMat.cols; ++col) {
            p++;  //points to each pixel value in turn assuming a CV_8UC1 greyscale image
            
            if ( (uint8_t)(*p) < 127 )
                pos.push_back( col );
            else
                pos.clear();
            
            
            if ( pos.size() > 3 ) {
                float value =  (float)pos[0]/WIDTH;
                
//                float alpha = mAlpha1 + (mAlpha2 - mAlpha1)*value;
//                float C0 = cos( mAlpha2 );
//                float C1 =1/( cos( mAlpha1) - C0 );
                
                //value = C1 * ( cos( alpha ) - C0 );
                //timeline().apply( &mSliderPos, value, 0.01f/*, EaseInCubic() */);
                
                mSliderPos = value;
                if ( mSliderTouchState == false )
                {
                    mSliderTouchState = true;
                    // Send Slider Touch On Message
                    osc::Message message2;
                    message2.addIntArg( (int)mSliderTouchState );
                    //    message.setAddress("/cinder/osc/1");
                    message2.setRemoteEndpoint(mOSCHost, mOSCPort2);
                    mOSCSender2.sendMessage(message2);
                    
                    console() << (int)mSliderTouchState  << endl;

                }
                
                return value;
                
            }
        }
    }
    
    if ( mSliderTouchState == true )
    {
        mSliderTouchState = false;
        // Send Slider Touch Off Message in no activity detecded
        osc::Message message2;
        message2.addIntArg( (int)mSliderTouchState );
        //    message.setAddress("/cinder/osc/1");
        message2.setRemoteEndpoint(mOSCHost, mOSCPort2);
        mOSCSender2.sendMessage(message2);
        
        console() << (int)mSliderTouchState  << endl;
    }
    
    
    return 0.f;
}

NCCASoundArtApp::~NCCASoundArtApp()
{
    savePointsOfPerspectiveCorrection();
}

CINDER_APP_NATIVE( NCCASoundArtApp, RendererGl )
