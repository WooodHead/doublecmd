unit uMultiArchiveCopyOutOperation;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StringHashList, uLog, uGlobs, un_process,
  uFileSourceOperation,
  uFileSourceCopyOperation,
  uFileSourceOperationOptions,
  uFileSourceOperationOptionsUI,
  uFileSource,
  uFile,
  uMultiArchiveFileSource;

type

  { TMultiArchiveCopyOutOperation }

  TMultiArchiveCopyOutOperation = class(TFileSourceCopyOutOperation)

  private
    FMultiArchiveFileSource: IMultiArchiveFileSource;
    FStatistics: TFileSourceCopyOperationStatistics; // local copy of statistics
    FFullFilesTreeToExtract: TFiles;  // source files including all files/dirs in subdirectories

    // Options
    FPassword: UTF8String;
    FExtractWithoutPath: Boolean;
    FFileExistsOption: TFileSourceOperationOptionFileExists;

    {en
      Creates neccessary paths before extracting files from archive.

      @param(Files
             List of files/directories to extract (relative to archive root).)
      @param(sDestPath
             Destination path where the files will be extracted.)
      @param(CurrentArchiveDir
             Path inside the archive from where the files will be extracted.)
      @param(CreatedPaths
             This list will be filled with absolute paths to directories
             that were created, together with their attributes.)}
    procedure CreateDirs(const theFiles: TFiles; sDestPath: String;
                                      CurrentArchiveDir: String;
                                      var CreatedPaths: TStringHashList);

    {en
      Sets attributes for directories.
      @param(Paths
             The list of absolute paths, which attributes are to be set.
             Each list item's data field must be a pointer to TMultiArchiveFile,
             from where the attributes are retrieved.}
    function SetDirsAttributes(const Paths: TStringHashList): Boolean;

    function DoFileExists(const AbsoluteTargetFileName: String): TFileSourceOperationOptionFileExists;

    procedure ShowError(sMessage: String; logOptions: TLogOptions = []);
    procedure LogMessage(sMessage: String; logOptions: TLogOptions; logMsgType: TLogMsgType);
    procedure CheckForErrors(const SourceName, TargetName: UTF8String; ExitStatus: LongInt);

  protected
    FExProcess: TExProcess;
    FTempFile: UTF8String;
    FFileMask: UTF8String;
    FErrorLevel: LongInt;
    procedure OnReadLn(str: string);
    procedure OnQueryString(str: string);
    procedure UpdateProgress(SourceName, TargetName: UTF8String; IncSize: Int64);
    procedure FileSourceOperationStateChangedNotify(Operation: TFileSourceOperation;
                                                    AState: TFileSourceOperationState);

  public
    constructor Create(aSourceFileSource: IFileSource;
                       aTargetFileSource: IFileSource;
                       var theSourceFiles: TFiles;
                       aTargetPath: String); override;

    destructor Destroy; override;

    procedure Initialize; override;
    procedure MainExecute; override;
    procedure Finalize; override;

    class function GetOptionsUIClass: TFileSourceOperationOptionsUIClass; override;

    property Password: UTF8String read FPassword write FPassword;
    property FileExistsOption: TFileSourceOperationOptionFileExists read FFileExistsOption write FFileExistsOption;
    property ExtractWithoutPath: Boolean read FExtractWithoutPath write FExtractWithoutPath;
  end;

implementation

uses
  LCLProc, FileUtil, uOSUtils, DCOSUtils, DCStrUtils, uMultiArc, uFileSourceOperationUI, fMultiArchiveCopyOperationOptions,
  uMultiArchiveUtil, uFileProcs, uLng, DCDateTimeUtils, DCBasicTypes, uShowMsg;

constructor TMultiArchiveCopyOutOperation.Create(aSourceFileSource: IFileSource;
                                               aTargetFileSource: IFileSource;
                                               var theSourceFiles: TFiles;
                                               aTargetPath: String);
begin
  FMultiArchiveFileSource := aSourceFileSource as IMultiArchiveFileSource;
  FFullFilesTreeToExtract:= nil;
  FFileExistsOption := fsoofeNone;
  FExtractWithoutPath:= False;

  inherited Create(aSourceFileSource, aTargetFileSource, theSourceFiles, aTargetPath);
end;

destructor TMultiArchiveCopyOutOperation.Destroy;
begin
  FreeThenNil(FFullFilesTreeToExtract);
  inherited Destroy;
end;

procedure TMultiArchiveCopyOutOperation.Initialize;
begin
  FExProcess:= TExProcess.Create(EmptyStr);
  FExProcess.OnReadLn:= @OnReadLn;
  FExProcess.OnOperationProgress:= @CheckOperationState;
  FTempFile:= GetTempName(GetTempFolder);

  with FMultiArchiveFileSource.MultiArcItem do
  if Length(FPasswordQuery) <> 0 then
  begin
    FExProcess.QueryString:= UTF8ToConsole(FPasswordQuery);
    FExProcess.OnQueryString:= @OnQueryString;
  end;

  AddStateChangedListener([fsosStarting, fsosPausing, fsosStopping], @FileSourceOperationStateChangedNotify);

  // Get initialized statistics; then we change only what is needed.
  FStatistics := RetrieveStatistics;

  FFileMask := ExtractFileName(TargetPath);
  if FFileMask = '' then FFileMask := '*';  // extract all selected files/folders

  with FMultiArchiveFileSource do
  FillAndCount(FFileMask, SourceFiles,
               True,
               FFullFilesTreeToExtract,
               FStatistics.TotalFiles,
               FStatistics.TotalBytes);     // gets full list of files (recursive)
end;

procedure TMultiArchiveCopyOutOperation.MainExecute;
var
  TargetFileName,
  SourcePath,
  sTempDir: UTF8String;
  CreatedPaths: TStringHashList = nil;
  I: Integer;
  aFile: TFile;
  MultiArcItem: TMultiArcItem;
  sReadyCommand,
  sCommandLine: UTF8String;
  FilesToExtract: TFiles = nil;
begin
  MultiArcItem := FMultiArchiveFileSource.MultiArcItem;
  try
    // Archive current path
    SourcePath:= ExcludeFrontPathDelimiter(SourceFiles.Path);
    // Check ExtractWithoutPath option
    if FExtractWithoutPath then
      sCommandLine:= MultiArcItem.FExtractWithoutPath
    else
      begin
        // Create needed directories.
        CreatedPaths := TStringHashList.Create(True);
        CreateDirs(FFullFilesTreeToExtract, TargetPath, SourcePath, CreatedPaths);
        sCommandLine:= MultiArcItem.FExtract;
      end;
    // Get maximum acceptable command errorlevel
    FErrorLevel:= ExtractErrorLevel(sCommandLine);
    if Pos('%F', sCommandLine) <> 0 then // extract file by file
      for I:= 0 to FFullFilesTreeToExtract.Count - 1 do
      begin
        CheckOperationState;
        aFile:= FFullFilesTreeToExtract[I];
        // Now check if the file is to be extracted.
        if (not aFile.AttributesProperty.IsDirectory) then  // Omit directories (we handle them ourselves).
          begin
            // Check ExtractWithoutPath option
            if FExtractWithoutPath then
              TargetFileName := TargetPath + aFile.Name
            else
              TargetFileName := TargetPath + ExtractDirLevel(SourcePath, aFile.FullPath);

            // Check existence of target file
            if (DoFileExists(TargetFileName) <> fsoofeOverwrite) then
              Continue;

            // Get target directory
            sTempDir:= ExtractFileDir(TargetFileName);

            UpdateProgress(aFile.FullPath, TargetFileName, 0);

            sReadyCommand:= FormatArchiverCommand(
                                                  MultiArcItem.FArchiver,
                                                  sCommandLine,
                                                  FMultiArchiveFileSource.ArchiveFileName,
                                                  nil,
                                                  aFile.FullPath,
                                                  TargetPath,
                                                  FTempFile,
                                                  FPassword
                                                  );
            OnReadLn(sReadyCommand);

            // Set target directory as archiver current directory
            FExProcess.Process.CurrentDirectory:= mbFileNameToSysEnc(sTempDir);
            FExProcess.SetCmdLine(sReadyCommand);
            FExProcess.Execute;

            UpdateProgress(aFile.FullPath, TargetFileName, aFile.Size);
            // Check for errors.
            CheckForErrors(aFile.FullPath, TargetFileName, FExProcess.ExitStatus);
          end;
    end // for
  else  // extract whole file list
    begin
      sTempDir:= TargetPath; // directory where files will be unpacked
      // if extract from not root directory and with path
      if (SourceFiles.Path <> PathDelim) and (FExtractWithoutPath = False) then
        begin
          sTempDir:= GetTempName(TargetPath);
          mbCreateDir(sTempDir);
        end;

      // Check existence of target files
      FilesToExtract:= TFiles.Create(FFullFilesTreeToExtract.Path);
      for I:= 0 to FFullFilesTreeToExtract.Count - 1 do
      begin
        aFile:= FFullFilesTreeToExtract[I];
        if FExtractWithoutPath then
           TargetFileName := TargetPath + aFile.Name
        else
           TargetFileName := TargetPath + ExtractDirLevel(SourcePath, aFile.FullPath);
        if (DoFileExists(TargetFileName) = fsoofeOverwrite) then
          FilesToExtract.Add(aFile.Clone);
      end;

      sReadyCommand:= FormatArchiverCommand(
                                            MultiArcItem.FArchiver,
                                            sCommandLine,
                                            FMultiArchiveFileSource.ArchiveFileName,
                                            FilesToExtract,
                                            EmptyStr,
                                            TargetPath,
                                            FTempFile,
                                            FPassword
                                            );
      OnReadLn(sReadyCommand);

      // Set target directory as archiver current directory
      FExProcess.Process.CurrentDirectory:= mbFileNameToSysEnc(sTempDir);
      FExProcess.SetCmdLine(sReadyCommand);
      FExProcess.Execute;

      // Check for errors.
      CheckForErrors(FMultiArchiveFileSource.ArchiveFileName, EmptyStr, FExProcess.ExitStatus);

      // if extract from not root directory and with path
      if (SourceFiles.Path <> PathDelim) and (FExtractWithoutPath = False) then
      begin
        // move files to real target directory
        for I:= 0 to FilesToExtract.Count - 1 do
        begin
          aFile:= FilesToExtract[I];
          if not aFile.AttributesProperty.IsDirectory then
            begin
              TargetFileName := TargetPath + ExtractDirLevel(SourcePath, aFile.FullPath);
              UpdateProgress(aFile.FullPath, TargetFileName, 0);
              mbRenameFile(sTempDir + PathDelim + aFile.FullPath, TargetFileName);
              UpdateProgress(aFile.FullPath, TargetFileName, aFile.Size);
            end
        end;
        DelTree(sTempDir);
      end;
    end;

    if (FExtractWithoutPath = False) then SetDirsAttributes(CreatedPaths);

  finally
    FreeThenNil(CreatedPaths);
    FreeThenNil(FilesToExtract);
  end;
end;

procedure TMultiArchiveCopyOutOperation.Finalize;
begin
  FreeThenNil(FExProcess);
  with FMultiArchiveFileSource.MultiArcItem do
  if not FDebug then
    mbDeleteFile(FTempFile);
end;

procedure TMultiArchiveCopyOutOperation.CreateDirs(
              const theFiles: TFiles;
              sDestPath: String; CurrentArchiveDir: String;
              var CreatedPaths: TStringHashList);
var
  // List of paths that we know must be created.
  PathsToCreate: TStringHashList;

  // List of possible directories to create with their attributes.
  // This hash list is created to speed up searches for attributes in archive file list.
  DirsAttributes: TStringHashList;

  i: Integer;
  CurrentFileName: String;
  aFile: TFile;
  Directories: TStringList;
  PathIndex: Integer;
  ListIndex: Integer;
  TargetDir: String;
begin
  { First, collect all the paths that need to be created and their attributes. }

  PathsToCreate := TStringHashList.Create(True);
  DirsAttributes := TStringHashList.Create(True);

  for I := 0 to theFiles.Count - 1 do
  begin
    aFile := theFiles[I];

    if aFile.AttributesProperty.IsDirectory then
      begin
        CurrentFileName := ExtractDirLevel(CurrentArchiveDir, aFile.FullPath);

        // Save this directory and a pointer to its entry.
        DirsAttributes.Add(CurrentFileName, aFile);

        // Paths in PathsToCreate list must end with path delimiter.
        CurrentFileName := IncludeTrailingPathDelimiter(CurrentFileName);

        if PathsToCreate.Find(CurrentFileName) < 0 then
          PathsToCreate.Add(CurrentFileName);
      end
    else
      begin
        CurrentFileName := ExtractDirLevel(CurrentArchiveDir, aFile.Path);

        // If CurrentFileName is empty now then it was a file in current archive
        // directory, therefore we don't have to create any paths for it.
        if Length(CurrentFileName) > 0 then
          if PathsToCreate.Find(CurrentFileName) < 0 then
            PathsToCreate.Add(CurrentFileName);
      end;
  end;

  { Second, create paths and save which paths were created and their attributes. }

  Directories := TStringList.Create;

  try
    sDestPath := IncludeTrailingPathDelimiter(sDestPath);

    // Create path to destination directory (we don't have attributes for that).
    mbForceDirectory(sDestPath);

    CreatedPaths.Clear;

    for PathIndex := 0 to PathsToCreate.Count - 1 do
    begin
      Directories.Clear;

      // Create also all parent directories of the path to create.
      // This adds directories to list in order from the outer to inner ones,
      // for example: dir, dir/dir2, dir/dir2/dir3.
      if GetDirs(PathsToCreate.List[PathIndex]^.Key, Directories) <> -1 then
      try
        for i := 0 to Directories.Count - 1 do
        begin
          TargetDir := sDestPath + Directories.Strings[i];

          if (CreatedPaths.Find(TargetDir) = -1) and
             (not DirPathExists(TargetDir)) then
          begin
             if mbForceDirectory(TargetDir) = False then
             begin
               // Error, cannot create directory.
               Break; // Don't try to create subdirectories.
             end
             else
             begin
               // Retrieve attributes for this directory, if they are stored.
               ListIndex := DirsAttributes.Find(Directories.Strings[i]);
               if ListIndex <> -1 then
                 aFile := TFile(DirsAttributes.List[ListIndex]^.Data)
               else
                 aFile := nil;

               CreatedPaths.Add(TargetDir, aFile);
             end;
          end;
        end;
      except
      end;
    end;

  finally
    FreeAndNil(PathsToCreate);
    FreeAndNil(DirsAttributes);
    FreeAndNil(Directories);
  end;
end;

function TMultiArchiveCopyOutOperation.SetDirsAttributes(const Paths: TStringHashList): Boolean;
var
  PathIndex: Integer;
  TargetDir: String;
  aFile: TFile;
  Time: TFileTime;
begin
  Result := True;

  for PathIndex := 0 to Paths.Count - 1 do
  begin
    // Get attributes.
    aFile := TFile(Paths.List[PathIndex]^.Data);

    if Assigned(aFile) then
    begin
      TargetDir := Paths.List[PathIndex]^.Key;

      try
{$IF DEFINED(MSWINDOWS)}
        // Restore attributes, e.g., hidden, read-only.
        // On Unix attributes value would have to be translated somehow.
        mbFileSetAttr(TargetDir, aFile.Attributes);
{$ENDIF}
       Time:= DateTimeToFileTime(aFile.ModificationTime);
        // Set creation, modification time
        mbFileSetTime(TargetDir, Time, Time, Time);

      except
        Result := False;
      end;
    end;
  end;
end;

function TMultiArchiveCopyOutOperation.DoFileExists(
  const AbsoluteTargetFileName: String): TFileSourceOperationOptionFileExists;
const
  PossibleResponses: array[0..4] of TFileSourceOperationUIResponse
    = (fsourOverwrite, fsourSkip, fsourOverwriteAll, fsourSkipAll, fsourCancel);
begin
  case FFileExistsOption of
    fsoofeNone:
      begin
        if not mbFileExists(AbsoluteTargetFileName) then
          Result:= fsoofeOverwrite
        else
          case AskQuestion(Format(rsMsgFileExistsRwrt, [AbsoluteTargetFileName]), '',
                           PossibleResponses, fsourOverwrite, fsourSkip) of
            fsourOverwrite:
              Result := fsoofeOverwrite;
            fsourSkip:
              Result := fsoofeSkip;
            fsourOverwriteAll:
              begin
                FFileExistsOption := fsoofeOverwrite;
                Result := fsoofeOverwrite;
              end;
            fsourSkipAll:
              begin
                FFileExistsOption := fsoofeSkip;
                Result := fsoofeSkip;
              end;
            fsourNone,
            fsourCancel:
              RaiseAbortOperation;
          end;
      end;

    else
      Result := FFileExistsOption;
  end;
end;

procedure TMultiArchiveCopyOutOperation.ShowError(sMessage: String; logOptions: TLogOptions);
begin
  if not gSkipFileOpError then
  begin
    if AskQuestion(sMessage, '', [fsourSkip, fsourCancel],
                   fsourSkip, fsourAbort) = fsourAbort then
    begin
      RaiseAbortOperation;
    end;
  end
  else
  begin
    LogMessage(sMessage, logOptions, lmtError);
  end;
end;

procedure TMultiArchiveCopyOutOperation.LogMessage(sMessage: String; logOptions: TLogOptions; logMsgType: TLogMsgType);
begin
  case logMsgType of
    lmtError:
      if not (log_errors in gLogOptions) then Exit;
    lmtInfo:
      if not (log_info in gLogOptions) then Exit;
    lmtSuccess:
      if not (log_success in gLogOptions) then Exit;
  end;

  if logOptions <= gLogOptions then
  begin
    logWrite(Thread, sMessage, logMsgType);
  end;
end;

procedure TMultiArchiveCopyOutOperation.CheckForErrors(const SourceName,
                                                       TargetName: UTF8String;
                                                       ExitStatus: LongInt);
begin
  if ExitStatus > FErrorLevel then
    begin
      ShowError(Format(rsMsgLogError + rsMsgLogExtract,
                       [FMultiArchiveFileSource.ArchiveFileName + PathDelim +
                        SourceName + ' -> ' + TargetName +
                        ' - Exit status: ' + IntToStr(ExitStatus)]), [log_arc_op]);
    end // Error
  else
    begin
      LogMessage(Format(rsMsgLogSuccess + rsMsgLogExtract,
                        [FMultiArchiveFileSource.ArchiveFileName + PathDelim +
                         SourceName +' -> ' + TargetName]), [log_arc_op], lmtSuccess);
    end; // Success
end;

procedure TMultiArchiveCopyOutOperation.OnReadLn(str: string);
begin
  with FMultiArchiveFileSource.MultiArcItem do
  if FOutput or FDebug then
    logWrite(Thread, str, lmtInfo, True, False);
end;

procedure TMultiArchiveCopyOutOperation.OnQueryString(str: string);
var
  sPassword: UTF8String;
  pcPassword: PAnsiChar;
begin
  ShowInputQuery(FMultiArchiveFileSource.MultiArcItem.FDescription, rsMsgPasswordEnter, True, sPassword);
  pcPassword:= PAnsiChar(UTF8ToConsole(sPassword + #13#10));
  FExProcess.Process.Input.Write(pcPassword^, Length(pcPassword));
end;

procedure TMultiArchiveCopyOutOperation.UpdateProgress(SourceName,
  TargetName: UTF8String; IncSize: Int64);
begin
  with FStatistics do
  begin
    FStatistics.CurrentFileFrom:= SourceName;
    FStatistics.CurrentFileTo:= TargetName;

    CurrentFileDoneBytes:= IncSize;
    DoneBytes := DoneBytes + CurrentFileDoneBytes;

    UpdateStatistics(FStatistics);
  end;
end;

procedure TMultiArchiveCopyOutOperation.FileSourceOperationStateChangedNotify(
  Operation: TFileSourceOperation; AState: TFileSourceOperationState);
begin
  case AState of
    fsosStarting:
      FExProcess.Process.Resume;
    fsosPausing:
      FExProcess.Process.Suspend;
    fsosStopping:
      FExProcess.Stop;
  end;
end;

class function TMultiArchiveCopyOutOperation.GetOptionsUIClass: TFileSourceOperationOptionsUIClass;
begin
  Result:= TMultiArchiveCopyOperationOptionsUI;
end;

end.

